# su_mcp/su_mcp/ui/settings_dialog.rb
require "json"

module SU_MCP
  module UI
    module SettingsDialog
      HTML_PATH    = File.join(File.dirname(__FILE__), "settings.html").freeze
      DIALOG_TITLE = "MCP Server Settings"
      # Derive prefs_key from the Config section name so all our SU prefs
      # cluster together. SketchUp uses this only for remembering dialog
      # position/size — not related to our host/port/log_level prefs.
      DIALOG_PREFS = "#{SU_MCP::Core::Config::SECTION}_SettingsDialog".freeze

      @dialog = nil

      # Idempotent: refresh state and bring existing dialog to front instead of
      # opening a second one. Always refreshing means the dialog stays accurate
      # even if the server was toggled through the main menu in the meantime.
      def self.show
        if @dialog && @dialog.visible?
          on_load_state(@dialog)
          @dialog.bring_to_front
          return
        end
        @dialog = build_dialog
        @dialog.show
      end

      def self.build_dialog
        dialog = ::UI::HtmlDialog.new(
          dialog_title:    DIALOG_TITLE,
          preferences_key: DIALOG_PREFS,
          scrollable:      false,
          resizable:       false,
          width:           420,
          height:          340,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        dialog.add_action_callback("load_state") { |_ctx|       on_load_state(dialog) }
        dialog.add_action_callback("save")       { |_ctx, json| on_save(dialog, json) }
        dialog.add_action_callback("cancel")     { |_ctx|       dialog.close }

        dialog.set_file(HTML_PATH)
        dialog
      end

      # Push current Config + Application state into the dialog. Called on
      # initial DOM ready, after Save, and on show() when reopening.
      def self.on_load_state(dialog)
        state = {
          host:      SU_MCP::Core::Config.host,
          port:      SU_MCP::Core::Config.port,
          log_level: SU_MCP::Core::Config.log_level,
          running:   SU_MCP::Core::Application.running?,
          current:   SU_MCP::Core::Application.running_config
        }
        dialog.execute_script("window.applyState(#{js_safe_json(state)})")
      rescue StandardError => e
        SU_MCP::Core::Logger.log_error("settings_dialog.load_state", e)
      end

      def self.on_save(dialog, json)
        payload = JSON.parse(json)
        result  = SettingsValidator.validate(payload)

        unless result[:ok]
          dialog.execute_script(
            "window.onSaveResult(#{js_safe_json({ ok: false, errors: result[:errors] })})"
          )
          return
        end

        normalized = result[:normalized]
        # Snapshot what the server is *actually* running on (not the
        # last-saved Config). Reverting saved values back to running values
        # therefore does not provoke a restart prompt.
        current_runtime = SU_MCP::Core::Application.running_config

        SU_MCP::Core::Config.update!(
          host:      normalized[:host],
          port:      normalized[:port],
          log_level: normalized[:log_level]
        )

        dialog.execute_script("window.onSaveResult(#{js_safe_json({ ok: true })})")
        # Refresh the form + status banner with what was actually persisted.
        on_load_state(dialog)

        need_restart = current_runtime &&
                       (normalized[:host] != current_runtime[:host] ||
                        normalized[:port] != current_runtime[:port])

        if need_restart
          # Wrap UI.messagebox in UI.start_timer so it does not run inside the
          # action_callback stack — a known Windows quirk that can sink the
          # message box behind the main SketchUp window and freeze the UI.
          ::UI.start_timer(0, false) do
            answer = ::UI.messagebox("Restart server with new settings now?", MB_YESNO)
            SU_MCP::Core::Application.restart if answer == IDYES
            # After restart, refresh dialog state if it's still open so the
            # status block reflects the new running config.
            on_load_state(dialog) if @dialog && @dialog.visible?
          end
        end
      rescue StandardError => e
        SU_MCP::Core::Logger.log_error("settings_dialog.save", e)
        # Sanitize e.message in case it carries invalid UTF-8 or quotes that
        # would break JSON.generate or be misinterpreted by the HTML parser.
        safe_msg = e.message.to_s.encode("utf-8", invalid: :replace, undef: :replace)
        dialog.execute_script(
          "window.onSaveResult(#{js_safe_json({ ok: false, errors: { _general: "Internal error: #{safe_msg}" } })})"
        )
      end

      # JSON.generate does not escape "</" inside a <script> block context.
      # Even though our payload is locally sourced, defense-in-depth: replace
      # "</" → "<\/" so the JSON literal cannot prematurely terminate the
      # script tag context if it were ever embedded that way.
      def self.js_safe_json(value)
        JSON.generate(value).gsub("</", "<\\/")
      end
    end
  end
end
