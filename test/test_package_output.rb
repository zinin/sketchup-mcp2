# test/test_package_output.rb
# Контракт единственного артефакта: package.rb собирает ровно один .rbz,
# имя которого не несёт суффикса сборки, а в корне архива лежат только
# загрузчик и одноимённая папка — сервис подписи Trimble отвергает всё
# остальное в корне с «Extra files found».
require "minitest/autorun"
require "open3"
require "fileutils"
require "tmpdir"
require "zip"

class TestPackageOutput < Minitest::Test
  PKG_DIR = File.expand_path("../mcp_for_sketchup", __dir__)

  # Прежние артефакты убираются В СТОРОНУ на время прогона, а не удаляются.
  # Убирать нужно, иначе `assert_equal 1` проверяет не этот прогон. Удалять
  # нельзя: подпись .rbz жива (docs/release.md §3 — самообслуживаемый сервис
  # Trimble), поэтому снесённый подписанный артефакт стоит не пересборки, а
  # повторного круга через сервис. `ruby test/run_all.rb`, запущенный между
  # подписанием и загрузкой релиза, не должен обходиться пользователю в это.
  def setup
    @stash = Dir.mktmpdir("rbz-stash")
    Dir.chdir(PKG_DIR) do
      Dir.glob("mcp_for_sketchup_v*.rbz").each do |f|
        FileUtils.mv(f, File.join(@stash, File.basename(f)))
      end
    end
  end

  # Порядок обязателен: сначала убрать артефакт ЭТОГО прогона, потом вернуть
  # чужие — иначе возвращённый одноимённый тут же попал бы под удаление.
  def teardown
    Dir.chdir(PKG_DIR) do
      Dir.glob("mcp_for_sketchup_v*.rbz").each { |f| File.delete(f) }
      Dir.glob(File.join(@stash, "*.rbz")).each do |f|
        FileUtils.mv(f, File.basename(f))
      end
    end
    FileUtils.remove_entry(@stash)
  end

  def test_package_rb_emits_one_unsuffixed_rbz_with_a_correct_loader
    Dir.chdir(PKG_DIR) do
      # stderr захватываем, а не выбрасываем: post-build-проверки внутри
      # package.rb (загрузчик на месте, display-имя, версия) прерывают
      # сборку сообщением о том, какая именно не прошла. С err: File::NULL
      # любая из них выглядит как безликое «exited non-zero».
      _out, err, status = Open3.capture3({ "RUBYOPT" => nil }, "ruby", "package.rb")
      assert status.success?, "package.rb exited non-zero; stderr:\n#{err}"

      files = Dir.glob("mcp_for_sketchup_v*.rbz")
      assert_equal 1, files.length,
        "package.rb must emit exactly one .rbz; got #{files.inspect}"
      assert_match(/\Amcp_for_sketchup_v\d+\.\d+\.\d+\.rbz\z/, files.first,
        "artifact must be named mcp_for_sketchup_v<X.Y.Z>.rbz; got #{files.first.inspect}")

      Zip::File.open(files.first) do |zf|
        roots = zf.entries.map { |e| e.name.split("/").first }.uniq.sort
        assert_equal ["mcp_for_sketchup", "mcp_for_sketchup.rb"], roots,
          "archive root must hold only the loader and its same-named folder; got #{roots.inspect}"

        # Содержимое, а не только корень. package.rb делает cp_r ВСЕЙ подпапки,
        # поэтому посторонний файл внутри неё уезжает в подписываемый артефакт
        # молча — корневой ассерт выше этого не видит. Ручная сверка содержимого
        # (§7 docs/release.md) снята вместе с warehouse-процедурой, так что это
        # единственное, что теперь держит инвариант.
        #
        # Эталон берём из git, а не с диска: сравнение с диском пропустило бы
        # ровно тот случай, ради которого проверка и нужна — нетрекнутый
        # stale-генерат (например, core/build_profile.rb от сборки до 0.3.1)
        # лежал бы тогда в обоих множествах и сошёлся бы сам с собой.
        tracked, st = Open3.capture2("git", "ls-files",
                                     "mcp_for_sketchup", "mcp_for_sketchup.rb")
        assert st.success?, "git ls-files failed; тест требует git-checkout"
        expected = tracked.split("\n").sort
        refute_empty expected, "git ls-files вернул пустой список — не тот каталог?"
        packaged = zf.entries.reject(&:directory?).map(&:name).sort
        assert_equal expected, packaged,
          "архив обязан содержать ровно трекнутое дерево расширения; лишний " \
          "файл уедет в подписанный .rbz, недостающий сломает загрузку"

        loader = zf.find_entry("mcp_for_sketchup.rb")
        refute_nil loader, "loader mcp_for_sketchup.rb missing from #{files.first}"
        body = loader.get_input_stream.read
        assert_includes body, "'MCP Server for SketchUp'",
          "loader must declare the display name"
        assert_match(/ext\.version\s*=\s*'\d+\.\d+\.\d+'/, body,
          "loader must declare an X.Y.Z version")
      end
    end
  end
end
