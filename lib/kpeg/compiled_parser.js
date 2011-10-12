KPeg = {};

KPeg.CompiledParser = function(str, debug) {
  this.setup_parser(str, debug || false);
};

KPeg.CompiledParser.extend = function(props) {
  var subclass = function() { KPeg.CompiledParser.apply(this, arguments); };
  subclass.prototype = Object.create(KPeg.CompiledParser.prototype);

  for (var prop in props) {
    if (props.hasOwnProperty(prop)) {
      subclass.prototype[prop] = props[prop];
    }
  }

  return subclass;
};

KPeg.ParseError = function(message) {
  this.name = "KPeg.ParseError";
  this.message = (message || "");
};
KPeg.prototype = new Error;

KPeg.LeftRecursive = function(detected) {
  this.detected = detected || false;
};

KPeg.MemoEntry = function(ans, pos) {
  this.ans = ans;
  this.pos = pos;
  this.uses = 1;
  this.result = null;
};

KPeg.MemoEntry.prototype = {
  doInc: function() {
    this.uses++;
  },

  doMove: function(ans, pos, result) {
    this.ans = ans;
    this.pos = pos;
    this.result = result;
  }
};

KPeg.RuleInfo = function(name, rendered) {
  this.name = name;
  this.rendered = rendered;
}

KPeg.rule_info = function(name, rendered) {
  return new KPeg.RuleInfo(name, rendered);
}

KPeg.CompiledParser.prototype = {
  setup_parser: function(str, debug) {
    this.string = str;
    this.pos = 0;
    this.memoizations = {};
    this.result = null;
    this.failed_rule = null;
    this.failing_rule_offset = -1;

    //return this.setup_foreign_grammar();
  },

  _memoization_for: function(key) {
    var memo = this.memoizations[key];
    if (!memo) { memo = this.memoizations[key] = {}; }
    return memo;
  },

  // include position

  get_text: function(start) {
    return this.string.slice(start);
  },

  show_pos: function() {
    var width = 10, string = this.string, pos = this.pos;

    if (pos < width) {
      return pos + ' ("' + string.slice(0, pos) + 
        '" @ "' + string.slice(pos, pos + width);
    } else {
      return pos + ' ("... ' + string.slice(pos - width, pos) + '" @ "' + 
        string.slice(pos, pos + width);
    }
  },

  failure_info: function() {
    var l = this.current_line(this.failing_rule_offset);
    var c = this.current_column(this.failing_rule_offset);

    if (this.failed_rule instanceof KPeg.Symbol) {
      var info = this.Rules[this.failed_rule];
      return "line " + l + ", column " + d + 
        ": failed rule '" + info.name + "' = '" + 
        info.rendered + "'";
    } else {
      return "line " + line + ", column " + c +
        ": failed rule '" + this.failed_rule
    }
  },

  failure_caret: function() {
    var l = this.current_line(this.failing_rule_offset);
    var c = this.current_column(this.failing_rule_offset);

    var line = lines[l-1];
    return line + "\n" + Array(c).join(" ") + "^";
  },

  failure_character: function() {
    var l = this.current_line(this.failing_rule_offset);
    var c = this.current_column(this.failing_rule_offset);

    return this.lines[l-1].charAt(c);
  },

  failure_oneline: function() {
    var l = this.current_line(this.failing_rule_offset);
    var c = this.current_column(this.failing_rule_offset);
    
    var char = this.lines[l-1].charAt(c);

    var info = this.Rules[this.failed_rule];
    var name = info ? info.name : this.failed_rule;

    return "@" + l + ":" + c + " failed rule '" + name + "', got '" + char + "'";
  },

  raise_error: function() {
    throw new KPeg.ParseError(this.failure_oneline());
  },

  // TODO: show_error

  set_failed_rule: function(name) {
    if (this.pos > this.failing_rule_offset) {
      this.failed_rule = name;
      this.failing_rule_offset = this.pos;
    }
  },

  match_string: function(str) {
    var len = str.length;

    if (this.string.slice(this.pos, this.pos + len) == str) {
      this.pos += len;
      return str;
    }

    return null;
  },

  scan: function(reg) {
    var m = reg.exec(this.string.slice(this.pos));

    if (m) {
      var width = m.index + m[0].length;
      this.pos += width;
      return true;
    }

    return null;
  },

  get_byte: function() {
    if (this.pos >= this.string.size) {
      return null;
    }

    var s = this.string.charCodeAt(this.pos);
    this.pos += 1;
    return s;
  },

  parse: function(rule) {
    rule = rule || null;

    if (!rule) {
      return this._root() ? true : false;
    } else {
      var method = rule.replace(/-/g, '_hyphen');
      return this['_' + method]() ? true : false;
    }
  },

  external_invoke: function(other, rule) {
    var old_pos = this.pos;
    var old_string = this.string;

    this.pos = other.pos;
    this.string = other.string;

    var args = [].slice.call(arguments, 2);

    try {
      var val = this[rule].apply(this, args);

      if (val) {
        other.pos = this.pos;
        other.result = this.result;
      } else {
        // TODO: set class_name on the parser
        other.set_failed_rule("#" + rule);
      }
    } finally {
      this.pos = old_pos;
      this.string = old_string;
    }
  },

  apply_with_args: function(rule) {
    var args = [].slice.call(arguments, 1);

    // TODO: Figure out memo
  },

  apply: function(rule) {
    var memo = this._memoization_for(rule);
    var m = memo[this.pos];

    if (m) {
      m.doInc();

      var prev = this.pos;
      this.pos = m.pos;

      if (m.ans instanceof KPeg.LeftRecursive) {
        m.ans.detected = true;
        return null;
      }

      this.result = m.result;

      return m.ans;
    } else {
      var lr = new KPeg.LeftRecursive(false);
      m = new KPeg.MemoEntry(lr, this.pos);

      memo[this.pos] = m;
      var start_pos = this.pos;

      var ans = this[rule]();

      m.doMove(ans, this.pos, this.result);

      // Don't bother trying to grow the left recursion
      // if it's failing straight away (thus there is no seed)
      if (ans && lr.detected) {
        return this.grow_lr(rule, null, start_pos, m);
      }

      return ans;
    }
  },

  grow_lr: function(rule, args, start_pos, m) {
    var ans;

    while (true) {
      this.pos = start_pos;
      this.result = m.result

      if (args) {
        ans = this[rule].apply(this, args);  
      } else {
        ans = this[rule]();
      }

      if (!ans) { return null; }
      if (this.pos <= m.pos) { break; }

      m.doMove(ans, this.pos, this.result);
    }

    this.result = m.result;
    this.pos = m.pos;
    return m.ans;
  }
};

if (typeof exports === undefined) {
  window.KPeg = KPeg;
} else {
  module.exports = KPeg;
}
