require 'kpeg/grammar_renderer'
require 'stringio'

module KPeg
  class JavaScriptGenerator
    def initialize(name, gram, debug=false)
      @name = name
      @grammar = gram
      @debug = debug
      @saves = 0
      @locals = []
      @output = nil
      @standalone = false
    end

    attr_accessor :standalone

    def method_name(name)
      name = name.gsub("-","_hyphen_")
      "_#{name}"
    end

    def save
      if @saves == 0
        str = "_save"
      else
        str = "_save#{@saves}"
      end

      use_local str
      @saves += 1
      str
    end

    def use_local(name)
      @locals |= [name]
    end

    def reset_locals
      @saves = 0
      @locals = []
    end

    def ast_for(code, klass, attrs)
      code = ""
      code   << "    #{klass}: function(#{attrs.join(', ')}) {\n"
      attrs.each do |at|
        code << "      this.#{at} = #{at};\n"
      end
      code   << "    }"
    end

    def handle_ast(code)
      root = @grammar.variables["ast-location"] || "AST"
      methods = []

      ast = @grammar.variables.select { |k,v| v =~ /^ast / }
      ast = ast.sort_by { |k,v| k }

      unless ast.empty?
        code   << "  #{root}: {\n"

        ast_code = []

        ast.each do |name, value|
          parser = FormatParser.new(value[4..-1])

          # TODO: w0t
          next unless parser.parse("ast_root")

          klass, attrs = parser.result

          ast_code << ast_for(code, klass, attrs)
          methods << [name, klass, attrs]
        end

        code   << ast_code.join(",\n")
        code   << "\n  },\n"

        methods.each do |name, klass, attrs|
          attrs = attrs.join(', ')
          code << "  #{name}: function(#{attrs}) {\n"
          code << "    return new #{@name}.#{root}.#{klass}(#{attrs});\n"
          code << "  },\n"
        end
      end
    end
    
    def indentify(code, indent)
      "#{"  " * indent}#{code}"
    end
    
    # Default indent is 4 spaces (indent=2)
    def output_op(code, op, indent=2)
      case op
      when Dot
        code << indentify("_tmp = this.get_byte()\n", indent)
      when LiteralString
        code << indentify("_tmp = this.match_string(#{op.string.dump});\n", indent)
      when LiteralRegexp
        code << indentify("_tmp = this.scan(/^#{op.regexp.source}/);\n", indent)
      when CharRange
        ss = save()
        if op.start.bytesize == 1 and op.fin.bytesize == 1
          code << indentify("#{ss} = this.pos;\n", indent)
          code << indentify("_tmp = this.get_byte();\n", indent)
          code << indentify("if (_tmp) {\n", indent)

          if op.start.respond_to? :getbyte
            left  = op.start.getbyte 0
            right = op.fin.getbyte 0
          else
            left  = op.start[0]
            right = op.fin[0]
          end
          
          code << indentify("  if (_tmp < #{left} || _tmp > #{right} {\n", indent)
          code << indentify("    this.pos = #{ss};\n", indent)
          code << indentify("    _tmp = null;\n", indent)
          code << indentify("  }\n", indent)
          code << indentify("}\n", indent)
        else
          raise "Unsupported char range - #{op.inspect}"
        end
      when Choice
        ss = save()
        code << "\n"
        code << indentify("#{ss} = this.pos;\n", indent)
        code << indentify("while (true) { // choice\n", indent)
        op.ops.each_with_index do |n,idx|
          output_op code, n, (indent+1)
          
          code << indentify("  if (_tmp) { break; }\n", indent)
          code << indentify("  this.pos = #{ss};\n", indent)
          if idx == op.ops.size - 1
            code << indentify("  break;\n", indent)
          end
        end
        code << indentify("} // end choice\n\n", indent)
      when Multiple
        ss = save()
        if op.min == 0 and op.max == 1
          code << indentify("#{ss} = this.pos\n", indent)
          output_op code, op.op, indent
          if op.save_values
            code << indentify("if (!_tmp) { this.result = null; }\n", indent)
          end
          code << indentify("if (!_tmp) {\n", indent)
          code << indentify("  _tmp = true;\n", indent)
          code << indentify("  this.pos = #{ss};\n", indent)
          code << indentify("}\n", indent)
        elsif op.min == 0 and !op.max
          if op.save_values
            use_local "_ary"
            code << indentify("_ary = [];\n", indent)
          end

          code << indentify("while (true) {\n", indent)
          output_op code, op.op, (indent+1)
          if op.save_values
            code << indentify("  if (_tmp) { _ary.push(this.result); }\n", indent)
          end
          code << indentify("  if (!_tmp) { break; }\n", indent)
          code << indentify("}\n", indent)
          code << indentify("_tmp = true;\n", indent)

          if op.save_values
            code << indentify("this.result = _ary;\n", indent)
          end

        elsif op.min == 1 and !op.max
          code << indentify("#{ss} = self.pos;\n", indent)
          if op.save_values
            use_local "_ary"
            code << indentify("_ary = [];\n", indent)
          end
          output_op code, op.op, indent
          code << indentify("if (_tmp) {\n", indent)
          if op.save_values
            code << indentify("  _ary.push(this.result);\n", indent)
          end
          code << indentify("  while (true) {\n", indent)
          output_op code, op.op, (indent+2)
          if op.save_values
            code << indentify("    if (_tmp) { _ary.push(this.result); }\n", indent)
          end
          code << indentify("    if (!_tmp) { break; }\n", indent)
          code << indentify("  }\n", indent)
          code << indentify("  _tmp = true;\n", indent)
          if op.save_values
            code << indentify("  this.result = _ary;\n", indent)
          end
          code << indentify("} else {\n", indent)
          code << indentify("  this.pos = #{ss};\n", indent)
          code << indentify("}\n", indent)
        else
          code << indentify("#{ss} = this.pos;\n", indent)

          use_local('_count')
          code << indentify("_count = 0;\n", indent)
          code << indentify("while (true) {\n", indent)
          output_op code, op.op, (indent+1)
          code << indentify("  if (_tmp) {\n", indent)
          code << indentify("    _count++;\n", indent)
          code << indentify("    if (_count === #{op.max}) { break; }\n", indent)
          code << indentify("  } else {\n", indent)
          code << indentify("    break;\n", indent)
          code << indentify("  }\n", indent)
          code << indentify("}\n", indent)
          code << indentify("if (_count >= #{op.min}) {\n", indent)
          code << indentify("  _tmp = true;\n", indent)
          code << indentify("} else {\n", indent)
          code << indentify("  this.pos = #{ss};\n", indent)
          code << indentify("  _tmp = null;\n", indent)
          code << indentify("}\n", indent)
        end

      when Sequence
        ss = save()
        code << "\n"
        code << indentify("#{ss} = self.pos;\n", indent)
        code << indentify("while (true) { // sequence\n", indent)
        op.ops.each_with_index do |n, idx|
          output_op code, n, (indent+1)

          if idx == op.ops.size - 1
            code << indentify("  if (!_tmp) {\n", indent)
            code << indentify("    this.pos = #{ss};\n", indent)
            code << indentify("  }\n", indent)
            code << indentify("  break;\n", indent)
          else
            code << indentify("  if (!_tmp) {\n", indent)
            code << indentify("    this.pos = #{ss};\n", indent)
            code << indentify("    break;\n", indent)
            code << indentify("  }\n", indent)
          end
        end
        code << indentify("} // end sequence\n\n", indent)
      when AndPredicate
        ss = save()
        code << indentify("#{ss} = this.pos\n", indent)
        if op.op.kind_of? Action
          code << indentify("_tmp = #{op.op.action};\n", indent)
        else
          output_op code, op.op, indent
        end
        code << indentify("this.pos = #{ss};\n", indent)
      when NotPredicate
        ss = save()
        code << indentify("#{ss} = this.pos;\n", indent)
        if op.op.kind_of? Action
          code << indentify("_tmp = #{op.op.action};\n", indent)
        else
          output_op code, op.op, indent
        end
        code << indentify("_tmp = _tmp ? null : true\n", indent)
        code << indentify("this.pos = #{ss};\n", indent)
      when RuleReference
        if op.arguments
          code << indentify("_tmp = this.apply_with_args('#{method_name op.rule_name}', #{op.arguments[1..-2]});\n", indent)
        else
          code << indentify("_tmp = this.apply('#{method_name op.rule_name}');\n", indent)
        end
      when InvokeRule
        if op.arguments
          code << indentify("_tmp = #{method_name op.rule_name}#{op.arguments}\n", indent)
        else
          code << indentify("_tmp = #{method_name op.rule_name}()\n", indent)
        end
      when ForeignInvokeRule
        if op.arguments
          code << indentify("_tmp = this._grammar_#{op.grammar_name}.external_invoke(this, '#{method_name op.rule_name}', #{op.arguments[1..-2]})\n", indent)
        else
          code << indentify("_tmp = this._grammar_#{op.grammar_name}.external_invoke(this, '#{method_name op.rule_name}')\n", indent)
        end
      when Tag
        if op.tag_name and !op.tag_name.empty?
          output_op code, op.op, indent

          use_local(op.tag_name)
          code << indentify("#{op.tag_name} = this.result;\n", indent)
        else
          output_op code, op.op, indent
        end
      when Action
        code << indentify("this.result = #{op.action};\n", indent)
        if @debug
          code << indentify("puts \"   => \" #{op.action.dump} \" => \#{@result.inspect} \\n\"\n", indent)
        end
        code << indentify("_tmp = true;\n", indent)
      when Collect
        use_local('_text_start')
        use_local('text')

        code << indentify("_text_start = this.pos;\n", indent)
        output_op code, op.op, indent
        code << indentify("if (_tmp) {\n", indent)
        code << indentify("  text = this.get_text(_text_start);\n", indent)
        code << indentify("}\n", indent)
      when Bounds
        use_local('_bounds_start')
        use_local('bounds')

        code << indentify("_bounds_start = this.pos;\n", indent)
        output_op code, op.op, indent
        code << indentify("if (_tmp) {\n", indent)
        code << indentify("  bounds = [_bounds_start, this.pos];\n", indent)
        code << indentify("}\n", indent)
      else
        raise "Unknown op - #{op.class}"
      end

    end

    def standalone_region(path)
      cp = File.read(path)
      start = cp.index("// STANDALONE START")
      fin = cp.index("// STANDALONE END")

      return nil unless start and fin
      cp[start..fin]
    end

    def output
      return @output if @output
      if @standalone
        code = "class #{@name}\n"

        unless cp = standalone_region(
                    File.expand_path("../compiled_parser.rb", __FILE__))

          puts "Standalone failure. Check compiler_parser.rb for proper boundary comments"
          exit 1
        end

        unless pp = standalone_region(
                    File.expand_path("../position.rb", __FILE__))
          puts "Standalone failure. Check position.rb for proper boundary comments"
        end

        cp.gsub!(/include Position/, pp)
        code << cp << "\n"
      else
        code = "#{@name} = KPeg.CompiledParser.extend({\n"
      end

      handle_ast(code)

      @grammar.setup_actions.each do |act|
        code << "\n#{act.action}\n\n"
      end

      fg = @grammar.foreign_grammars

      if fg.empty?
        if @standalone
          code << "  def setup_foreign_grammar; end\n"
        end
      else
        code << "  def setup_foreign_grammar\n"
        @grammar.foreign_grammars.each do |name, gram|
          code << "    @_grammar_#{name} = #{gram}.new(nil)\n"
        end
        code << "  end\n"
      end

      render = GrammarRenderer.new(@grammar)

      renderings = {}

      @grammar.rule_order.each do |name|
        reset_locals

        rule = @grammar.rules[name]
        io = StringIO.new
        render.render_op io, rule.op

        rend = io.string
        rend.gsub! "\n", " "

        renderings[name] = rend

        code << "\n"
        code << "  // #{name} = #{rend}\n"

        if rule.arguments
          code << "  #{method_name name}: function(#{rule.arguments.join(',')}) {\n"
        else
          code << "  #{method_name name}: function() {\n"
        end

        pre_code = code
        code = ""

        #code << "    var _tmp;\n"

        if @debug
          code << "    puts \"START #{name} @ \#{show_pos}\\n\"\n"
        end

        output_op code, rule.op

        if @debug
          code << "    if _tmp\n"
          code << "      puts \"   OK #{name} @ \#{show_pos}\\n\"\n"
          code << "    else\n"
          code << "      puts \" FAIL #{name} @ \#{show_pos}\\n\"\n"
          code << "    end\n"
        end

        code << "    if (!_tmp) { this.set_failed_rule('#{method_name name}'); }\n"
        code << "    return _tmp;\n"
        code << "  },\n"

        locals = ["self = this", "_tmp"] + @locals
        locals = "    var #{locals.join(', ')};\n"
        code = pre_code + locals + code
      end

      code << "\n  Rules: {\n"

      rules = []

      @grammar.rule_order.each do |name|
        rule = @grammar.rules[name]

        rend = GrammarRenderer.escape renderings[name], true
        rules << "    #{method_name name}: KPeg.rule_info('#{name}', '#{rend}')"
      end

      code << rules.join(",\n")
      code << "\n  }\n});\n"

      code << "if (typeof exports === undefined) {\n"
      code << "  window.#{@name} = #{@name};\n"
      code << "} else {\n"
      code << "  module.exports = #{@name};\n"
      code << "}\n\n"

      @output = code
    end

    def make(str)
      m = Module.new
      m.module_eval output

      cls = m.const_get(@name)
      cls.new(str)
    end

    def parse(str)
      make(str).parse
    end
  end
end
