# Copyright 2010-2016, Raphael Reitzig
# <code@verrech.net>
#
# This file is part of ltx2any.
#
# ltx2any is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ltx2any is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with ltx2any. If not, see <http://www.gnu.org/licenses/>.

require 'singleton'

Dependency.new('listen', :gem, [:core, 'FileListener'], :recommended, 'Listening to files for automatic recompilation.', '>=3.1.5')

ParameterManager.instance.addParameter(Parameter.new(
    :daemon, 'd', Boolean, false, 'Re-compile automatically when files change.'))
ParameterManager.instance.addParameter(Parameter.new(
    :listeninterval, 'di', Float, 0.5,
    'Time after which daemon mode checks for changes (in seconds).'))

class FileListener
  include Singleton

  private

  def ignoreFileName(jobname = '')
    ".#{NAME}ignore_#{jobname}"
  end

  public

  def initialize
    @ignore = []
    #ParameterManager.instance.addHook(:listeninterval) { |_,v|
      # TODO implement hook that catches changes to listen interval
    #}
    @jobfilelistener = nil
    @ignfilelistener = nil
    @dependencies = DependencyManager.list(source: [:core, self.class.to_s])
  end

  def ignored
    @ignore.clone
  end

  # Function that reads the ignorefile fo another process and
  # adds the contained files to the ignore list.
  def readIgnoreFile(ignoreFile)
    if File.exist?(ignoreFile)
      IO.foreach(ignoreFile) { |line|
        @ignore.push(line.strip)
      }
    end
  end

  def start(jobname, ignores = [])
    # Make sure that the listen gem is available
    @dependencies.each { |d|
      if !d.available?
        raise MissingDependencyError.new(d.to_s)
      end
    }
        
    if @jobfilelistener != nil 
      # Should never happen unless I programmed crap
      raise StandardError.new('Listener already running, what are you doing?!')
    end
    
    params = ParameterManager.instance

    # Add the files to ignore from this process
    @ignore += ignores
    @ignorefile = ignoreFileName(jobname)
    @ignore.push(@ignorefile)

    # Write ignore list for other processes
    File.open("#{params[:jobpath]}/#{@ignorefile}", 'w') { |file|
      file.write(@ignore.join("\n"))
      # TODO make sure this file gets deleted!
    }

    # Collect all existing ignore files
    Dir.entries('.') \
      .select { |f| /(\.\/)?#{Regexp.escape(ignoreFileName(''))}[^\/]+/ =~ f } \
      .each { |f|
      readIgnoreFile(f)
    }


    # Setup daemon mode
    @vanishedfiles = []
    # Main listener: this one checks job files for changes and prompts recompilation.
    #                (indirectly: The Loop below checks $changetime.)
    @jobfilelistener =
      Listen.to('.',
                latency: params[:listeninterval] * 0.25,
                ignore: [ /(\.\/)?#{Regexp.escape(ignoreFileName())}[^\/]+/,
                          #/(\.\/)?\..*/, # ignore hidden files, e.g. .git
                          /\A(\.\/)?(#{@ignore.map { |s| Regexp.escape(s) }.join('|')})/ ],
               ) \
      do |modified, added, removed|
        # TODO cruel hack; can we do better?
        removed.each { |r|
          @vanishedfiles.push File.path(r.to_s).sub(params[:jobpath], params[:tmpdir])
        }
        @changetime = Time.now
      end

      params.addHook(:listeninterval) { |key,val|
        # jobfilelistener.latency = val
        # TODO tell change to listener; in worst case, restart?
      }
      # TODO need hook on -i parameter?

      # Secondary listener: this one checks for (new) ignore files, i.e. other
      #                     jobs in the same directory. It then updates the main
      #                     listener so that it does not react to changes in files
      #                     generated by the other process.
      @ignfilelistener =
        Listen.to('.',
                  only: /\A(\.\/)?#{Regexp.escape(ignoreFileName())}[^\/]+/,
                  latency: 0.1
                 ) \
        do |modified, added, removed|
          @jobfilelistener.pause

          added.each { |ignf|
            files = ignoremore(ignf)
            @jobfilelistener.ignore(/\A(\.\/)?(#{files.map { |s| Regexp.escape(s) }.join('|')})/)
          }

          # TODO If another daemon terminates we keep its ignorefiles. Potential leak!
          #      If this turns out to be a problem, update list & listener (from scratch)

          @jobfilelistener.unpause
        end

      @ignfilelistener.start
      @changetime = Time.now
      @lastraise  = @changetime
      @jobfilelistener.start
  end

  def waitForChanges(output)
    output.start('Waiting for file changes (press ENTER to pause)')
    @jobfilelistener.start if @jobfilelistener.paused?
    params = ParameterManager.instance
    
    files = Thread.new do
      while @changetime <= @lastraise || Time.now - @changetime < params[:listeninterval]
        sleep(params[:listeninterval] * 0.5)
      end

      @lastraise = Time.now
      Thread.current[:raisetarget].raise(FilesChanged.new('Files have changed'))
    end
    files[:raisetarget] = Thread.current
    
    begin
      files.run
      STDIN.noecho(&:gets)
       # User wants to enter prompt, so stop listening
      files.kill
      @jobfilelistener.pause
      output.stop(:cancel)

      # Delegate. The method returns if the user
      # prompts a rerun. It throws a SystemExit
      # exception if the user wants to quit.
      DaemonPrompt.run
    rescue FilesChanged => e
      # Rerun!
      output.stop(:success)
      @jobfilelistener.pause
    rescue Interrupt => e 
      # User hit CTRL+C while waiting
      raise e
    rescue SystemExit => e
      # User issued :quit in DaemonPrompt. So it shall be!
      raise e
    end

    # Remove files reported missing since last run from tmp (so we don't hide errors)
    # Be extra careful, we don't want to delete non-tmp files!
    @vanishedfiles.each { |f| FileUtils.rm_rf(f) if f.start_with?(params[:tmpdir]) && File.exists?(f) }
    @vanishedfiles = []
  end

  def pause
    @jobfilelistener.pause
  end


  def stop
    begin
      @jobfilelistener.stop
    rescue Exception, Error
      # Apparently, stopping throws exceptions.
    end
    begin
      @ignfilelistener.stop
    rescue Exception, Error
      # Apparently, stopping throws exceptions.
    end
    cleanup
  end

  def runs?
    !@jobfile.nil?
  end


  private

  # Removes temporary files outside of the tmp folder,
  # closes file handlers, etc.
  def cleanup
    # TODO this really needs to be done via CLEAN
    FileUtils::rm("#{ParameterManager.instance[:jobpath]}/#{@ignorefile}")
  end


  class FilesChanged < StandardError; end
end
