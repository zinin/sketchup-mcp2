# mcp_for_sketchup/mcp_for_sketchup/ui/settings_dialog.rb
require "json"

module MCPforSketchUp
  module UI
    module SettingsDialog
      HTML_PATH    = File.join(File.dirname(__FILE__), "settings.html").freeze
      DIALOG_TITLE = "MCP Server for SketchUp Settings"
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
          scrollable:      true,
          resizable:       false,
          width:           380,
          height:          480,
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

      # Build the state payload pushed to the dialog. Extracted so the
      # two-phase confirm flow in `on_save` can also use it to revert
      # the UI to the previously-saved state when the user declines.
      def self.load_state_payload
        {
          host:           MCPforSketchUp::Core::Config.host,
          port:           MCPforSketchUp::Core::Config.port,
          log_level:      MCPforSketchUp::Core::Config.log_level,
          log_to_file:    MCPforSketchUp::Core::Config.log_to_file,
          log_file_path:  MCPforSketchUp::Core::Config.log_file_path,
          # Use eval_enabled? (not raw accessor) so sentinel-nil unset state
          # falls through to BuildProfile::EVAL_ENABLED_BY_DEFAULT — iter-1 CRITICAL-2.
          eval_enabled:   MCPforSketchUp::Core::Config.eval_enabled?,
          running:        MCPforSketchUp::Core::Application.running?,
          current:        MCPforSketchUp::Core::Application.running_config,
        }
      end

      # Push current Config + Application state into the dialog. Called on
      # initial DOM ready, after Save, and on show() when reopening.
      def self.on_load_state(dialog)
        dialog.execute_script("window.applyState(#{js_safe_json(load_state_payload)})")
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
        current_runtime = MCPforSketchUp::Core::Application.running_config
        # Effective previous state — uses `eval_enabled?` so a sentinel-nil
        # unset pref properly resolves through BuildProfile (iter-1 CRITICAL-2).
        previous_eval_enabled = MCPforSketchUp::Core::Config.eval_enabled?

        # Eval transition off → on requires a blocking confirm with a security
        # warning. Two-phase flow (iter-1 CRITICAL-3): we MUST leave the
        # action_callback frame before showing ::UI.messagebox — on Windows
        # a messagebox inside the callback hangs (same quirk handled at
        # settings_dialog.rb:100 for host/port restart). Defer via
        # ::UI.start_timer(0, false), then either persist (Yes) or revert
        # UI to the previously-saved state (No).
        if normalized[:eval_enabled] && !previous_eval_enabled
          ::UI.start_timer(0, false) do
            # iter-2 CRITICAL-2: the outer `rescue StandardError` on
            # `on_save` does NOT cover this block — the timer fires after
            # the action_callback frame returns. Without an in-timer rescue
            # an exception here (validator-validated payload that still
            # raises in update!, IO error inside dialog.execute_script,
            # etc.) would crash silently inside the timer and leave the
            # dialog open with no error feedback — it would never close or
            # revert.
            begin
              if confirm_eval_enable
                # User confirmed; persist via the shared finalizer so the
                # Yes path goes through the same need_restart / dialog.close
                # logic as the normal path.
                persist_and_finalize(dialog, normalized, current_runtime,
                                     override_eval_enabled: true)
              else
                # User declined; revert UI to the previously-saved state
                # and surface a one-line error.
                dialog.execute_script(
                  "window.applyState(#{js_safe_json(load_state_payload)}); " \
                  "window.onSaveResult(#{js_safe_json({ ok: false,
                    errors: { eval_enabled: 'Cancelled — no settings were saved (Ruby evaluation remains disabled)' } })})"
                )
              end
            rescue StandardError => e
              report_general_error(dialog, e, tag: "settings_dialog.eval_confirm", revert: true)
            end
          end
          return
        end

        persist_and_finalize(dialog, normalized, current_runtime)
      rescue StandardError => e
        report_general_error(dialog, e, tag: "settings_dialog.save")
      end

      # iter-2 CRITICAL-2: shared finalizer for `on_save`. Previously the
      # confirm-Yes branch had its own truncated finalizer that skipped
      # need_restart detection and dialog.close — only the normal path
      # ran them. Extracting both paths through this helper guarantees the
      # eval-enable confirmation flow behaves identically to a host/port
      # change w.r.t. restart prompt + dialog dismissal. `override_eval_enabled`
      # is set to true only by the post-confirm Yes branch (`normalized[:eval_enabled]`
      # already validates true there, but the explicit override keeps the
      # intent legible at the call site); the normal path passes nil to
      # use `normalized[:eval_enabled]` as-is.
      def self.persist_and_finalize(dialog, normalized, current_runtime, override_eval_enabled: nil)
        effective_eval = override_eval_enabled.nil? ? normalized[:eval_enabled] : override_eval_enabled

        MCPforSketchUp::Core::Config.update!(
          host:           normalized[:host],
          port:           normalized[:port],
          log_level:      normalized[:log_level],
          eval_enabled:   effective_eval,
          log_to_file:    normalized[:log_to_file],
          log_file_path:  normalized[:log_file_path],
        )

        dialog.execute_script(
          "window.onSaveResult(#{js_safe_json({ ok: true })}); " \
          "window.applyState(#{js_safe_json(load_state_payload)})"
        )

        need_restart = current_runtime &&
                       (normalized[:host] != current_runtime[:host] ||
                        normalized[:port] != current_runtime[:port])

        ::UI.start_timer(0, false) { dialog.close }

        if need_restart
          ::UI.start_timer(0, false) do
            answer = ::UI.messagebox("Restart server with new settings now?", ::MB_YESNO)
            MCPforSketchUp::Core::Application.restart if answer == ::IDYES
          end
        end
      end
      private_class_method :persist_and_finalize

      # Blocking native confirm. Yes → returns true. No → returns false.
      # Caller (`on_save`) is responsible for deferring via UI.start_timer
      # to escape the action_callback frame on Windows; this method itself
      # only shows the messagebox (iter-1 CRITICAL-3).
      def self.confirm_eval_enable
        answer = ::UI.messagebox(
          "You are about to enable Ruby evaluation.\n\n" \
          "This lets connected MCP clients run arbitrary Ruby code inside " \
          "SketchUp with FULL access to your filesystem, network, and shell.\n\n" \
          "Only enable this with MCP clients you fully trust.\n\n" \
          "Continue?",
          ::MB_YESNO,
        )
        answer == ::IDYES
      end

      # Report an unexpected exception to the dialog as a _general error.
      # When revert: true, also re-pushes the saved state so the form rolls
      # back. Sanitises e.message (scrub invalid UTF-8 → "?") and swallows a
      # secondary execute_script failure (the dialog may already be closing).
      def self.report_general_error(dialog, e, tag:, revert: false)
        MCPforSketchUp::Core::Logger.log_error(tag, e)
        safe_msg = e.message.to_s.scrub("?")
        payload  = { ok: false, errors: { _general: "Internal error: #{safe_msg}" } }
        script   = +""
        script << "window.applyState(#{js_safe_json(load_state_payload)}); " if revert
        script << "window.onSaveResult(#{js_safe_json(payload)})"
        begin
          dialog.execute_script(script)
        rescue StandardError
          nil
        end
      end
      private_class_method :report_general_error

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
