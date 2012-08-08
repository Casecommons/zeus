module Zeus
  class Server
    class ForkedProcess
      HasNoChildren = Class.new(Exception)

      attr_accessor :name
      attr_reader :pid
      def initialize(server)
        @server = server
      end

      def notify_feature(feature)
        @server.__CHILD__stage_has_feature(@name, feature)
      end

      def descendent_acceptors
        raise NotImplementedError
      end

      def process_type
        raise "NotImplementedError"
      end

      def setup_forked_process(close_parent_sockets)
        @server.__CHILD__close_parent_sockets if close_parent_sockets

        $0 = "zeus #{process_type}: #{@name}"

        pid = Process.pid
        @server.__CHILD__status(pid, :starting, @name)
        trap("INT") {
          @server.__CHILD__status(pid, :killing, @name)
          puts "exiting"
          exit 0
        }

        new_features = $LOADED_FEATURES - previously_loaded_features
        $previously_loaded_features = $LOADED_FEATURES.dup
        Thread.new {
          new_features.each { |f| notify_feature(f) }
        }
      end

      def previously_loaded_features
        defined?($previously_loaded_features) ? $previously_loaded_features : []
      end

      def kill_pid_on_exit(pid)
        currpid = Process.pid
        at_exit { Process.kill(9, pid) if Process.pid == currpid rescue nil }
      end

      def runloop!
        raise NotImplementedError
      end

      def before_setup
      end

      def after_setup
      end

      def run(close_parent_sockets = false)
        @pid = fork {
          before_setup
          setup_forked_process(close_parent_sockets)

          Zeus.run_after_fork!

          after_setup
          runloop!
        }
        kill_pid_on_exit(@pid)
        @pid
      end

    end

  end
end

