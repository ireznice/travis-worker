require 'multi_json'
require 'thread'
require 'celluloid'
require 'core_ext/hash/compact'
require 'travis/support'
require 'travis/worker/factory'
require 'travis/worker/virtual_machine'
require 'travis/worker/reporter'
require 'travis/worker/utils/hard_timeout'
require 'travis/worker/utils/serialization'
require 'travis/worker/job/runner'

module Travis
  module Worker
    class Instance
      include Celluloid
      include Logging

      log_header { "#{name}:worker:instance" }

      def self.create(name, config)
        Factory.new(name, config).worker
      end

      STATES = [:created, :starting, :ready, :working, :stopping, :stopped, :errored]

      attr_accessor :state
      attr_reader :name, :vm, :queue_name,
                  :subscription, :config, :payload, :last_error, :observers, :reporter

      def initialize(name, vm, queue_name, config, observers = [])
        raise ArgumentError, "worker name cannot be nil!" if name.nil?
        raise ArgumentError, "VM cannot be nil!" if vm.nil?
        raise ArgumentError, "config cannot be nil!" if config.nil?

        @name              = name
        @vm                = vm
        @queue_name        = queue_name
        @config            = config
        @observers         = Array(observers)

        # create the reporter early so it is not created within the `process` callback
        @reporter = Reporter.new(name,
           builds_publisher,
           logs_publisher
        )
      end

      def builds_publisher
        @builds_publisher ||= Travis::Amqp::Publisher.jobs('builds', unique_channel: true, dont_retry: true)
      end

      def logs_publisher
        @logs_publisher ||= Travis::Amqp::Publisher.jobs('logs', unique_channel: true, dont_retry: true)
      end

      def start
        set :starting
        vm.prepare
        open_channels
        declare_queues
        subscribe
        set :ready
      end
      log :start

      # need to relook at this method as it feels wrong to
      # report a worker at stopping while it is also working
      def stop(options = {})
        # set :stopping
        info "stopping job"
        unsubscribe
        kill if options[:force]
      end

      def cancel
        if @runner
          info "cancelling job"
          @runner.cancel
        else
          @job_canceled = true
          info "marked job for cancellation as it is not running yet"
        end
        # vm.shell.terminate("Worker #{name} was stopped forcefully.")
      end

      def process(message, payload)
        work(message, payload)
      rescue => error
        error_build(error, message) unless @job_canceled
      ensure
        reporter.reset
        @job_canceled = false
      end

      def work(message, payload)
        prepare(payload)

        info "starting job slug:#{self.payload['repository']['slug']} id:#{self.payload['job']['id']}"
        info "this is a requeued message" if message.redelivered?

        notify_job_received
        run_job

        finish(message)
      rescue VirtualMachine::VmFatalError => e
        error "the job (slug:#{self.payload['repository']['slug']} id:#{self.payload['job']['id']}) was requeued as the vm had a fatal error"
        finish(message, :restart => true)
      rescue Job::Runner::ConnectionError => e
        error "the job (slug:#{self.payload['repository']['slug']} id:#{self.payload['job']['id']}) was requeued as the runner had a connection error"
        finish(message, :restart => true)
      rescue MultiJson::DecodeError => e
        error "invalid JSON for a job, dropping message: #{e.message}"
        finish(message)
      end

      def report
        { :name => name, :host => host, :state => state, :last_error => last_error, :payload => payload }
      end

      def shutdown
        info "shutting down"
        stop
      end

      def working?
        @state == :working
      end

      def stopping?
        @state == :stopping
      end

      protected

      def open_channels
        # error handling happens on the per-channel basis, so using
        # one channel for one type of operation is a highly recommended practice. MK.
        build_consumer
      end

      def close_channels
        # channels may be nil in some tests that mock out #start and #stop. MK.
        build_consumer.unsubscribe if build_consumer.nil?
        reporting_channel.close if reporting_channel && reporting_channel.open?
      end

      def build_consumer
        @build_consumer ||= Travis::Amqp::Consumer.builds
      end

      def declare_queues
        # these are declared here mostly to aid development purposes. MK
        reporting_channel = Travis::Amqp.connection.create_channel
        reporting_channel.queue("reporting.jobs.builds", :durable => true)
        reporting_channel.queue("reporting.jobs.logs",   :durable => true)
      end

      def subscribe
        @subscription = @build_consumer.subscribe(:ack => true, :blocking => false, &method(:process))
      end

      def unsubscribe
        # due to some aspects of how RabbitMQ Java client works and MarchHare consumer
        # implementation that uses thread pools (JDK executor services), we need to shut down
        # consumers manually to guarantee that after disconnect we leave no active non-daemon
        # threads (that are pretty much harmless but JVM won't exit as long as they are running). MK.
        return if subscription.nil? || subscription.cancelled?
        if working?
          graceful_shutdown
        else
          info "unsubscribing from #{queue_name} right now"
          subscription.cancel
          sleep 2
          set :stopped
        end
      rescue StandardError => e
        puts e.inspect
        info "subscription is still active"
        graceful_shutdown
      end

      def graceful_shutdown
        info "unsubscribing from #{queue_name} once the current job has finished"
        @shutdown = true
      end

      def set(state)
        @state = state
        observers.each { |observer| observer.notify(report) }
        state
      end

      def prepare(payload)
        @last_error = nil
        @payload = decode(payload)
        Travis.uuid = @payload.delete(:uuid)
        set :working
      end
      log :prepare, :as => :debug

      def finish(message, opts = {})
        if @shutdown
          set :stopping
          stop
        end

        restart_job if opts[:restart]

        message.ack

        @payload = nil

        if working?
          set :ready
        elsif stopping?
          set :stopped
        end
      end
      log :finish, :params => false

      def error_build(error, message)
        log_errored_build(error)
        finish(message, restart: true)
        # stop
        set :errored
        sleep 10
        set :ready
      end
      log :error_build, :as => :debug

      def log_errored_build(error)
        @last_error = [error.message, error.backtrace].flatten.join("\n")
        log_exception(error)
        Raven.capture_exception(error)
      rescue => error
        $stderr.puts "ERROR: failed to log error: #{error}"
      end

      def host
        Travis::Worker.config.host
      end

      def decode(payload)
        Hashr.new(MultiJson.decode(payload))
      end

      def run_job
        @runner = nil

        vm_opts = {
          language: job_language,
          job_id: payload.job.id,
          custom_image: job_image,
          dist: job_dist,
          group: job_group
        }

        vm.sandboxed(vm_opts) do
          if @job_canceled
            reporter.send_log(payload.job.id, "\n\nDone: Job Cancelled\n")
            reporter.notify_job_finished(payload.job.id, 'canceled')
          else
            @runner = Job::Runner.new(self.payload, vm.session, reporter, vm.full_name, timeouts, name)
            @runner.run
          end
        end
      ensure
        # @runner.terminate if @runner && @runner.alive?
        @runner = nil
      end

      def timeouts
        { hard_limit: timeout(:hard_limit), log_silence: timeout(:log_silence) }
      end

      def timeout(type)
        timeout = payload.timeouts && payload.timeouts.send(type) || config.timeouts.send(type)
        timeout.to_i
      end

      def notify_job_received
        reporter.notify_job_received(self.payload['job']['id'])
      end

      def restart_job
        if reporter && payload['job']['id']
          info "requeuing job"
          Metriks.meter('worker.job.requeue').mark
          reporter.restart(payload['job']['id'])
        end
      end

      def job_language
        payload['config']['language']
      end

      def job_dist
        payload['config']['dist']
      end

      def job_group
        payload['config']['group']
      end

      def job_image
        payload['config']['osx_image']
      end
    end
  end
end
