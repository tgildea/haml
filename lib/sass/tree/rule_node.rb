require 'pathname'
require 'uri'

module Sass::Tree
  # A static node reprenting a CSS rule.
  #
  # @see Sass::Tree
  class RuleNode < Node
    # The character used to include the parent selector
    # @private
    PARENT = '&'

    # The CSS selectors for this rule.
    # Each string is a selector line, and the lines are meant to be separated by commas.
    # For example,
    #
    #     foo, bar, baz,
    #     bip, bop, bup
    #
    # would be
    #
    #     ["foo, bar, baz",
    #      "bip, bop, bup"]
    #
    # @return [Array<String>]
    attr_accessor :rules

    # The CSS selectors for this rule,
    # parsed for commas and parent-references.
    # It's only set once {Tree::Node#perform} has been called.
    #
    # It's an array of arrays of arrays.
    # The first level of arrays represents distinct lines in the Sass file;
    # the second level represents comma-separated selectors;
    # the third represents structure within those selectors,
    # currently only parent-refs (represented by `:parent`).
    # For example,
    #
    #     &.foo, bar, baz,
    #     bip, &.bop, bup
    #
    # would be
    #
    #     [[[:parent, ".foo"], ["bar"], ["baz"]],
    #      [["bip"], [:parent, ".bop"], ["bup"]]]
    #
    # @return [Array<Array<Array<String|Symbol>>>]
    attr_accessor :parsed_rules

    # The CSS selectors for this rule,
    # with all nesting and parent references resolved.
    # It's only set once {Tree::Node#cssize} has been called.
    #
    # The first level of arrays represents distinct lines in the Sass file;
    # the second level represents comma-separated selectors.
    # For example,
    #
    #     foo bar, baz,
    #     bang, bip bop, blip
    #
    # would be
    #
    #     [["foo bar", "baz"],
    #      ["bang", "bip bop", "blip"]]
    #
    # @return [Array<Array<String>>]
    attr_accessor :resolved_rules

    # How deep this rule is indented
    # relative to a base-level rule.
    # This is only greater than 0 in the case that:
    #
    # * This node is in a CSS tree
    # * The style is :nested
    # * This is a child rule of another rule
    # * The parent rule has properties, and thus will be rendered
    #
    # @return [Fixnum]
    attr_accessor :tabs

    # Whether or not this rule is the last rule in a nested group.
    # This is only set in a CSS tree.
    #
    # @return [Boolean]
    attr_accessor :group_end

    # @param rule [String] The first CSS rule. See \{#rules}
    def initialize(rule)
      @rules = [rule]
      @tabs = 0
      super()
    end

    # Compares the contents of two rules.
    #
    # @param other [Object] The object to compare with
    # @return [Boolean] Whether or not this node and the other object
    #   are the same
    def ==(other)
      self.class == other.class && rules == other.rules && super
    end

    # Adds another {RuleNode}'s rules to this one's.
    #
    # @param node [RuleNode] The other node
    def add_rules(node)
      @rules += node.rules
    end

    # @return [Boolean] Whether or not this rule is continued on the next line
    def continued?
      @rules.last[-1] == ?,
    end

    protected

    # Computes the CSS for the rule.
    #
    # @param tabs [Fixnum] The level of indentation for the CSS
    # @return [String] The resulting CSS
    def _to_s(tabs)
      tabs = tabs + self.tabs

      rule_separator = style == :compressed ? ',' : ', '
      line_separator = [:nested, :expanded].include?(style) ? ",\n" : rule_separator
      rule_indent = '  ' * (tabs - 1)
      per_rule_indent, total_indent = [:nested, :expanded].include?(style) ? [rule_indent, ''] : ['', rule_indent]

      total_rule = total_indent + resolved_rules.map do |line|
        per_rule_indent + line.join(rule_separator)
      end.join(line_separator)

      to_return = ''
      old_spaces = '  ' * (tabs - 1)
      spaces = '  ' * tabs
      if style != :compressed
        if @options[:debug_info]
          to_return << debug_info_rule.to_s(tabs) << "\n"
        elsif @options[:line_comments]
          to_return << "#{old_spaces}/* line #{line}"

          if filename
            relative_filename = if @options[:css_filename]
              begin
                Pathname.new(filename).relative_path_from(
                  Pathname.new(File.dirname(@options[:css_filename]))).to_s
              rescue ArgumentError
                nil
              end
            end
            relative_filename ||= filename
            to_return << ", #{relative_filename}"
          end

          to_return << " */\n"
        end
      end

      if style == :compact
        properties = children.map { |a| a.to_s(1) }.select{|a| a && a.length > 0}.join(' ')
        to_return << "#{total_rule} { #{properties} }#{"\n" if group_end}"
      elsif style == :compressed
        properties = children.map { |a| a.to_s(1) }.select{|a| a && a.length > 0}.join(';')
        to_return << "#{total_rule}{#{properties}}"
      else
        properties = children.map { |a| a.to_s(tabs + 1) }.select{|a| a && a.length > 0}.join("\n")
        end_props = (style == :expanded ? "\n" + old_spaces : ' ')
        to_return << "#{total_rule} {\n#{properties}#{end_props}}#{"\n" if group_end}"
      end

      to_return
    end

    # Runs any SassScript that may be embedded in the rule,
    # and parses the selectors for commas.
    #
    # @param environment [Sass::Environment] The lexical environment containing
    #   variable and mixin values
    def perform!(environment)
      @parsed_rules = @rules.map {|r| parse_selector(interpolate(r, environment))}
      super
    end

    # Converts nested rules into a flat list of rules.
    #
    # @param parent [RuleNode, nil] The parent node of this node,
    #   or nil if the parent isn't a {RuleNode}
    def _cssize(parent)
      node = super
      rules = node.children.select {|c| c.is_a?(RuleNode)}
      props = node.children.reject {|c| c.is_a?(RuleNode) || c.invisible?}

      unless props.empty?
        node.children = props
        rules.each {|r| r.tabs += 1} if style == :nested
        rules.unshift(node)
      end

      rules.last.group_end = true unless parent || rules.empty?

      rules
    end

    # Resolves parent references and nested selectors,
    # and updates the indentation based on the parent's indentation.
    #
    # @param parent [RuleNode, nil] The parent node of this node,
    #   or nil if the parent isn't a {RuleNode}
    # @raise [Sass::SyntaxError] if the rule has no parents but uses `&`
    def cssize!(parent)
      self.resolved_rules = resolve_parent_refs(parent && parent.resolved_rules)
      super
    end

    # A hash that will be associated with this rule in the CSS document
    # if the {file:SASS_REFERENCE.md#debug_info-option `:debug_info` option} is enabled.
    # This data is used by e.g. [the FireSass Firebug extension](https://addons.mozilla.org/en-US/firefox/addon/103988).
    #
    # @return [{#to_s => #to_s}]
    def debug_info
      {:filename => filename && ("file://" + URI.escape(File.expand_path(filename))),
       :line => self.line}
    end

    private

    def resolve_parent_refs(super_rules)
      if super_rules.nil?
        return @parsed_rules.map do |line|
          line.map do |rule|
            if rule.include?(:parent)
              raise Sass::SyntaxError.new("Base-level rules cannot contain the parent-selector-referencing character '#{PARENT}'.")
            end

            rule.join
          end.compact
        end
      end

      new_rules = []
      super_rules.each do |super_line|
        @parsed_rules.each do |line|
          new_rules << []

          super_line.each do |super_rule|
            line.each do |rule|
              rule = [:parent, " ", *rule] unless rule.include?(:parent)

              new_rules.last << rule.map do |segment|
                next segment unless segment == :parent
                super_rule
              end.join
            end
          end
        end
      end
      new_rules
    end

    def parse_selector(text)
      scanner = StringScanner.new(text)
      rules = [[]]

      while scanner.rest?
        rules.last << scanner.scan(/[^",&]*/)
        case scanner.scan(/./)
        when '&'; rules.last << :parent
        when ','
          scanner.scan(/\s*/)
          rules << [] if scanner.rest?
        when '"'
          rules.last << '"' << scanner.scan(/([^"\\]|\\.)*/)
          # We don't want to enforce that strings are closed,
          # but we do want to consume quotes or trailing backslashes.
          rules.last << scanner.scan(/./) if scanner.rest?
        end
      end

      rules.map! do |l|
        Haml::Util.merge_adjacent_strings(l).reject {|r| r.is_a?(String) && r.empty?}
      end

      rules
    end

    def debug_info_rule
      node = DirectiveNode.new("@media -sass-debug-info")
      debug_info.map {|k, v| [k.to_s, v.to_s]}.sort.each do |k, v|
        rule = RuleNode.new(nil)
        rule.resolved_rules = [[k.to_s.gsub(/[^\w-]/, "\\\\\\0")]]
        val = v.to_s.gsub(/[^\w-]/, "\\\\\\0").
          gsub(/^[\d-]/) {|c| "\\%04x " % Haml::Util.ord(c)}
        prop = PropNode.new("font-family", val, :new)
        rule << prop
        node << rule
      end
      node.options = @options.merge(:debug_info => false, :line_comments => false, :style => :compressed)
      node
    end
  end
end
