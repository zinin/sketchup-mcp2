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
      # The window's content area, in logical pixels: SketchUp multiplies them
      # by the display scaling. The settings are one compact column (Task 10)
      # and scroll inside it when they have to.
      DIALOG_WIDTH  = 560
      DIALOG_HEIGHT = 400

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
        fit_window(@dialog)
      end

      # SketchUp saves a dialog's size under its preferences_key and may reopen
      # it at that size — 500×780 from releases before the compact layout — so
      # the size is set again once the dialog is shown. set_content_size came
      # with SketchUp 2021.1; before it, set_size sets the outer frame.
      def self.fit_window(dialog)
        if dialog.respond_to?(:set_content_size)
          dialog.set_content_size(DIALOG_WIDTH, DIALOG_HEIGHT)
        else
          dialog.set_size(DIALOG_WIDTH, DIALOG_HEIGHT)
        end
      end
      private_class_method :fit_window

      def self.build_dialog
        dialog = ::UI::HtmlDialog.new(
          dialog_title:     DIALOG_TITLE,
          preferences_key:  DIALOG_PREFS,
          scrollable:       true,
          resizable:        false,
          # width and height are the content area, not the outer frame with
          # its title bar (SketchUp 2021.1+).
          use_content_size: true,
          width:            DIALOG_WIDTH,
          height:           DIALOG_HEIGHT,
          style:            ::UI::HtmlDialog::STYLE_DIALOG
        )

        dialog.add_action_callback("load_state") { |_ctx|       on_load_state(dialog) }
        dialog.add_action_callback("save")       { |_ctx, json| on_save(dialog, json) }
        # Defer dialog.close out of the JS action_callback frame for the same
        # Windows-quirk reason we wrap UI.messagebox below — cheap insurance.
        # close_dialog_safely guarantees @dialog is reset even if close raises.
        dialog.add_action_callback("cancel")     { |_ctx|       ::UI.start_timer(0, false) { close_dialog_safely(dialog) } }
        # M-06: Regenerate shows a native confirm, so it too leaves the
        # action_callback frame first (the Windows messagebox quirk below).
        dialog.add_action_callback("regenerate_token") { |_ctx| ::UI.start_timer(0, false) { on_regenerate_token(dialog) } }
        # §7.3: JavaScript cannot resolve names, so the host warning asks Ruby.
        dialog.add_action_callback("check_host") { |_ctx, host| on_check_host(dialog, host) }

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
          # Use eval_enabled? (not the raw accessor) so an unread pref resolves
          # to the shipped default instead of leaking nil — iter-1 CRITICAL-2.
          eval_enabled:   MCPforSketchUp::Core::Config.eval_enabled?,
          running:        MCPforSketchUp::Core::Application.running?,
          current:        MCPforSketchUp::Core::Application.running_config,
          # M-06: shown read-only, for Copy; the user never types it.
          token:          MCPforSketchUp::Core::Config.token,
          # §7.3: the saved host, by the check the server's bind warning uses.
          host_loopback:  MCPforSketchUp::Core::Net.loopback?(MCPforSketchUp::Core::Config.host),
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
        # Effective previous state — uses `eval_enabled?` so an unread pref
        # resolves to the shipped default (iter-1 CRITICAL-2).
        previous_eval_enabled = MCPforSketchUp::Core::Config.eval_enabled?

        # Eval transition off → on requires a blocking confirm with a security
        # warning. Two-phase flow (iter-1 CRITICAL-3): we MUST leave the
        # action_callback frame before showing ::UI.messagebox — on Windows
        # a messagebox inside the callback hangs (same quirk handled by the
        # host/port restart prompt in this file). Defer via
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

        ::UI.start_timer(0, false) { close_dialog_safely(dialog) }

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
          "This lets any MCP client that has the token run arbitrary Ruby code " \
          "inside SketchUp with FULL access to your filesystem, network, and " \
          "shell. The token keeps out clients that do not have it; the traffic " \
          "itself is not encrypted.\n\n" \
          "Only enable this on a machine and network you trust.\n\n" \
          "Continue?",
          ::MB_YESNO,
        )
        answer == ::IDYES
      end

      REGENERATE_PROMPT =
        "Regenerate the MCP token?\n\n" \
        "Every connected MCP client is disconnected now, and each one needs the " \
        "new token in SKETCHUP_MCP_TOKEN (and a restart of that client) before " \
        "it can connect again."

      # Blocking native confirm, like confirm_eval_enable; the caller defers it
      # out of the action_callback frame.
      def self.confirm_regenerate
        ::UI.messagebox(REGENERATE_PROMPT, ::MB_YESNO) == ::IDYES
      end

      # Settings → Regenerate (spec §7.1). The new token is saved before it takes
      # effect; then every client is closed, so sessions opened with the old
      # token end, and the dialog shows the new token — in the token field
      # only, so edits the user has not saved stay in the form. A failed save
      # keeps the old token, and the clients using it. Every path answers
      # onTokenResult, which re-enables the button the dialog disabled.
      def self.on_regenerate_token(dialog)
        unless confirm_regenerate
          dialog.execute_script("window.onTokenResult(#{js_safe_json({ ok: false, cancelled: true })})")
          return
        end
        begin
          MCPforSketchUp::Core::Config.regenerate_token!
        rescue StandardError => e
          MCPforSketchUp::Core::Logger.log_error("settings_dialog.regenerate_token", e)
          result = { ok: false, error: "Could not save the new token: #{e.message.to_s.scrub('?')}" }
          dialog.execute_script("window.onTokenResult(#{js_safe_json(result)})")
          return
        end
        MCPforSketchUp::Core::Application.disconnect_clients("token_regenerated")
        result = { ok: true, token: MCPforSketchUp::Core::Config.token }
        dialog.execute_script("window.onTokenResult(#{js_safe_json(result)})")
      rescue StandardError => e
        report_general_error(dialog, e, tag: "settings_dialog.regenerate_token")
      end

      # §7.3: whether the host typed in the dialog is loopback, by the server's
      # check, without a name lookup: it runs as the user types, on SketchUp's
      # UI thread (the dialog debounces the calls). A name counts as not
      # loopback until it is saved; the saved host is then judged with a lookup.
      def self.on_check_host(dialog, host)
        result = { host: host.to_s, loopback: MCPforSketchUp::Core::Net.loopback?(host, resolve: false) }
        dialog.execute_script("window.onHostCheck(#{js_safe_json(result)})")
      rescue StandardError => e
        MCPforSketchUp::Core::Logger.log_error("settings_dialog.check_host", e)
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
        rescue StandardError => e
          # The dialog may already be closing; nothing more we can do, but make
          # the swallowed failure diagnosable (DEBUG, suppressed by default)
          # instead of truly silent — consistent with the no-silent-rescues
          # convention.
          MCPforSketchUp::Core::Logger.log("DEBUG",
            "settings_dialog.report_general_error: secondary execute_script " \
            "failed: #{e.class}: #{e.message}")
        end
      end
      private_class_method :report_general_error

      # Close the dialog from inside a UI.start_timer callback, guaranteeing the
      # @dialog singleton is reset even if dialog.close raises. set_on_closed
      # normally nils @dialog, but it only fires on a *successful* close — if
      # close itself raises (historical SU quirk), @dialog would stay pointing at
      # a half-dead dialog and the next show() would probe .visible? on it (the
      # very thing set_on_closed guards against). The ensure makes the reset
      # unconditional. Matches the in-timer-rescue precedent in on_save.
      def self.close_dialog_safely(dialog)
        dialog.close
      rescue StandardError => e
        MCPforSketchUp::Core::Logger.log("DEBUG",
          "settings_dialog.close: dialog.close raised: #{e.class}: #{e.message}")
      ensure
        @dialog = nil
      end
      private_class_method :close_dialog_safely

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
