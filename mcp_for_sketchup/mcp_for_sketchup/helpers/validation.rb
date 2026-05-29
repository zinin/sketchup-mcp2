# mcp_for_sketchup/mcp_for_sketchup/helpers/validation.rb
module MCPforSketchUp
  module Helpers
    module Validation
      E = MCPforSketchUp::Core::StructuredError

      def self.require_string(params, key)
        v = params[key]
        raise E.new(-32602, "missing required field: #{key}") if v.nil?
        raise E.new(-32602, "field #{key} must be a string") unless v.is_a?(String)
        raise E.new(-32602, "field #{key} must not be empty") if v.empty?
        v
      end

      def self.require_positive(params, key)
        v = params[key]
        raise E.new(-32602, "missing required field: #{key}") if v.nil?
        raise E.new(-32602, "field #{key} must be a number") unless v.is_a?(Numeric)
        raise E.new(-32602, "field #{key} must be > 0, got #{v}") unless v > 0
        v
      end

      def self.require_enum(params, key, allowed)
        v = params[key]
        raise E.new(-32602, "missing required field: #{key}") if v.nil?
        unless allowed.include?(v)
          raise E.new(-32602, "field #{key} must be one of #{allowed}, got #{v.inspect}")
        end
        v
      end

      def self.require_coords3(params, key)
        v = params[key]
        raise E.new(-32602, "missing required field: #{key}") if v.nil?
        unless v.is_a?(Array) && v.length == 3
          raise E.new(-32602, "field #{key} must be a 3-element array")
        end
        v.each_with_index do |x, i|
          unless x.is_a?(Numeric)
            raise E.new(-32602, "field #{key}[#{i}] must be a number, got #{x.inspect}")
          end
        end
        v
      end

      def self.require_dimensions3(params, key)
        v = require_coords3(params, key)
        v.each_with_index do |x, i|
          raise E.new(-32602, "field #{key}[#{i}] must be > 0, got #{x}") unless x > 0
        end
        v
      end

      def self.require_id(params, key = "id")
        v = params[key]
        raise E.new(-32602, "missing required field: #{key}") if v.nil?
        int_id = Integer(v.to_s, 10) rescue nil
        if int_id.nil?
          raise E.new(-32602, "field #{key} must be an integer ID, got #{v.inspect}")
        end
        int_id
      end

      def self.optional_coords3(params, key)
        return nil unless params.key?(key)
        require_coords3(params, key)
      end

      def self.optional_positive(params, key, default = nil)
        return default unless params.key?(key)
        require_positive(params, key)
      end

      def self.optional_int_positive(params, key, default = nil)
        return default unless params.key?(key)
        v = params[key]
        raise E.new(-32602, "field #{key} must be an integer") unless v.is_a?(Integer)
        raise E.new(-32602, "field #{key} must be > 0, got #{v}") unless v > 0
        v
      end

      # Strict boolean: only TrueClass / FalseClass are accepted.
      # Reject coercion-style truthy values like "false", "0", 0, etc. —
      # JSON-RPC clients in dynamic languages can produce these unintentionally,
      # and Ruby treats every non-nil/non-false as truthy, which silently flips
      # destructive flags (e.g. boolean_operation:delete_originals).
      def self.optional_bool(params, key, default = false)
        return default unless params.key?(key)
        v = params[key]
        unless v == true || v == false
          raise E.new(-32602, "field #{key} must be a boolean (true/false), got #{v.inspect}")
        end
        v
      end
    end
  end
end
