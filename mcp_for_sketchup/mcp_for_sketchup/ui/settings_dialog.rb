# su_mcp/su_mcp/ui/settings_dialog.rb
require "json"

module MCPforSketchUp
  module UI
    module SettingsDialog
      HTML_PATH    = File.join(File.dirname(__FILE__), "settings.html").freeze
      DIALOG_TITLE = "MCP Server Settings"
      # Derive prefs_key from the Config section name so all our SU prefs
      # cluster together. SketchUp uses this only for remembering dialog
      # position/size — not related to our host/port/log_level prefs.
      DIALOG_PREFS = "#{MCPforSketchUp::Core::Config::SECTION}_SettingsDialog".freeze

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
          width:           380,
          height:          360,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        dialog.add_action_callback("load_state") { |_ctx|       on_load_state(dialog) }
        dialog.add_action_callback("save")       { |_ctx, json| on_save(dialog, json) }
        # Defer dialog.close out of the JS action_callback frame for the same
        # Windows-quirk reason we wrap UI.messagebox below — cheap insurance.
        dialog.add_action_callback("cancel")     { |_ctx|       ::UI.start_timer(0, false) { dialog.close } }

        # Drop the @dialog singleton on close (Save / Cancel / OS X-button) so
        # the next `show` rebuilds a fresh HtmlDialog instead of probing a
        # destroyed one via `@dialog.visible?` — defensive against historical
        # SU versions where visible? on a closed dialog could raise.
        dialog.set_on_closed { @dialog = nil }

        dialog.set_file(HTML_PATH)
        dialog
      end

      # Push current Config + Application state into the dialog. Called on
      # initial DOM ready, after Save, and on show() when reopening.
      def self.on_load_state(dialog)
        state = {
          host:      MCPforSketchUp::Core::Config.host,
          port:      MCPforSketchUp::Core::Config.port,
          log_level: MCPforSketchUp::Core::Config.log_level,
          running:   MCPforSketchUp::Core::Application.running?,
          current:   MCPforSketchUp::Core::Application.running_config
        }
        dialog.execute_script("window.applyState(#{js_safe_json(state)})")
      rescue StandardError => e
        MCPforSketchUp::Core::Logger.log_error("settings_dialog.load_state", e)
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
        current_runtime = MCPforSketchUp::Core::Application.running_config

        MCPforSketchUp::Core::Config.update!(
          host:      normalized[:host],
          port:      normalized[:port],
          log_level: normalized[:log_level]
        )

        dialog.execute_script("window.onSaveResult(#{js_safe_json({ ok: true })})")

        need_restart = current_runtime &&
                       (normalized[:host] != current_runtime[:host] ||
                        normalized[:port] != current_runtime[:port])

        # Defer dialog.close out of the JS action_callback frame for the same
        # Windows-quirk reason we wrap UI.messagebox below — cheap insurance.
        ::UI.start_timer(0, false) { dialog.close }

        if need_restart
          # Wrap UI.messagebox in UI.start_timer so it does not run inside the
          # action_callback stack — a known Windows quirk that can sink the
          # message box behind the main SketchUp window and freeze the UI.
          ::UI.start_timer(0, false) do
            answer = ::UI.messagebox("Restart server with new settings now?", ::MB_YESNO)
            MCPforSketchUp::Core::Application.restart if answer == ::IDYES
          end
        end
      rescue StandardError => e
        MCPforSketchUp::Core::Logger.log_error("settings_dialog.save", e)
        # Sanitize e.message in case it carries invalid UTF-8 bytes that would
        # break JSON.generate. scrub replaces invalid bytes with "?" verbatim.
        safe_msg = e.message.to_s.scrub("?")
        # Guard against the dialog being closed mid-save: if execute_script
        # itself fails, we have already logged the original cause above and
        # nothing more we can do — swallow secondary failure instead of
        # propagating it back across the SketchUp action_callback boundary.
        begin
          dialog.execute_script(
            "window.onSaveResult(#{js_safe_json({ ok: false, errors: { _general: "Internal error: #{safe_msg}" } })})"
          )
        rescue StandardError
          nil
        end
      end

      # JSON.generate does not escape "</" inside a <script> block context.
      # Even though our payload is locally sourced, defense-in-depth: replace
      # "</" → "<\/" so the JSON literal cannot prematurely terminate the
      # script tag context if it were ever embedded that way. Also escape
      # U+2028 / U+2029 — they are valid JSON but historically terminate JS
      # string literals on engines older than ES2019.
      def self.js_safe_json(value)
        JSON.generate(value)
          .gsub("</",       "<\\/")
          .gsub(" ",   "\\u2028")
          .gsub(" ",   "\\u2029")
      end
    end
  end
end
