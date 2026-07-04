# test/test_config_logger_guard.rb
# T-19: config.rb может исполняться ДО загрузки core/logger (ранний бут,
# точечный require в тестах). Если при этом кто-то в общем интерпретаторе
# SketchUp сделал require "logger", то defined?(Logger) находил stdlib
# ::Logger, и диагностический fallback падал NoMethodError (у stdlib Logger
# нет класс-метода .log) — ломая ровно тот путь, который защищал.
# Standalone-прогон этого файла дискриминирует баг (core/logger НЕ
# загружен); под run_all Core::Logger уже загружен — тест остаётся
# smoke-пином fallback-пути.
require "minitest/autorun"
require "logger"   # stdlib — имитация чужого require в shared-интерпретаторе

require_relative "../mcp_for_sketchup/mcp_for_sketchup/core/config"

class TestConfigLoggerGuard < Minitest::Test
  class PrefReader
    def read_default(_section, key, default = nil)
      key == "port" ? "not-a-port" : default
    end
  end

  def test_invalid_pref_fallback_survives_stdlib_logger_in_namespace
    MCPforSketchUp::Core::Config.load_from_defaults!(PrefReader.new)
    assert_equal 9876, MCPforSketchUp::Core::Config.port,
      "невалидный pref обязан откатиться к дефолту без исключения"
  end
end
