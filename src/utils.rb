# frozen_string_literal: true

require "open3"

module Utils
  # Uruchamia polecenie powłoki; loguje stdout/stderr na bieżąco.
  # Rzuca wyjątek jeśli proces zakończy się błędem.
  def self.run!(cmd, log)
    log.debug "$ #{cmd}"
    Open3.popen2e(cmd) do |_stdin, out_err, thread|
      out_err.each_line { |line| log.info "  #{line.chomp}" }
      status = thread.value
      raise "Polecenie zakończone błędem (exit #{status.exitstatus}): #{cmd}" unless status.success?
    end
  end

  # Sprawdza czy narzędzie jest dostępne w PATH
  def self.command_exist?(name)
    system("command -v #{name} > /dev/null 2>&1")
  end
end

# Dodaj .shellescape jeśli nie załadowano shellwords
class String
  require "shellwords"
  def shellescape
    Shellwords.escape(self)
  end
end
