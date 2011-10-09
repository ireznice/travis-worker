require 'spec_helper'
require 'stringio'

describe Logging::Logger do
  let(:logger) { Logging::Logger.new('vm') }

  before :each do
    Logging.io = StringIO.new
  end

  describe 'log' do
    it 'contains the log header' do
      logger.log(:before, :the_method, "Class")
      logger.io.string.should include('[vm]')
    end

    it 'contains the class the method was called from' do
      logger.log(:before, "Class", :the_method, [:foo, :bar])
      logger.io.string.should include('(Class)')
    end
    
    it 'contains the called method' do
      logger.log(:before, "Class", :the_method, [:foo, :bar])
      logger.io.string.should include('before :the_method(:foo, :bar)')
    end

    it 'colorizes the output (yellow)' do
      logger.log(:before, "Class", :the_method)
      logger.io.string.should include("\e[33m")
    end
  end

  describe 'error' do
    let(:error) { Exception.new('tis kaputt') }

    it 'contains the log header' do
      logger.error(error)
      logger.io.string.should include('[vm]')
    end

    it 'contains the error class name' do
      logger.error(error)
      logger.io.string.should include('Exception')
    end

    it 'contains the error message' do
      logger.error(error)
      logger.io.string.should include('tis kaputt')
    end

    it 'colorizes the output (red)' do
      logger.error(error)
      logger.io.string.should include("\e[31m")
    end
  end
end
