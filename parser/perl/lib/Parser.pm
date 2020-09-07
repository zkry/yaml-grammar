###
# This is a parser class. It has a parse() method and parsing primitives for
# the grammar. It calls methods in the receiver class, when a rule matches:
###

use v5.12;
package Parser;
use Prelude;
use base 'Grammar';

sub new {
  my ($class, $receiver) = @_;

  bless {
    receiver => $receiver,
    pos => 0,
    len => 0,
    stack => [],
    trace_num => 1,
    trace_off => 0,
    trace_info => ['', '', ''],
  }, $class;
}

sub parse {
  my ($self, $input, $rule, $trace) = @_;
  $self->{input} = $input;
  $rule //= $self->func('TOP');
  $trace //= false;

  $self->{len} = length $self->{input};

  *trace = \&noop;
  *trace = \&trace_func if $trace;

  my $ok;
  eval {
    $ok = $self->call($rule);
  };
  if ($@) {
    $self->trace_flush;
    die $@;
  }

  $self->trace_flush;

  if (not $ok) {
    die "Parser failed";
  }

  if ($self->{pos} < $self->{len}) {
    die "Parser finished before end of input";
  }

  return true;
}

sub state {
  $_[0]->{stack}[-1] || { lvl => 0 };
}

sub new_state {
  my ($self, $name) = @_;

  my $prev = $self->state;

  {
    name => $name,
    lvl => $prev->{lvl} + 1,
    pos => $self->{pos},
    m => undef,
  };
}

sub call {
  my ($self, $func, $type) = @_;
  $type //= 'boolean';

  my $args = [];
  if (isArray($func)) {
    ($func, @$args) = @$func;
    @$args = map {
      isArray($_) ? $self->call($_, 'any') :
      isFunction($_) ? $_->() :
      $_;
    } @$args;
  }

  return $func if $func eq $func + 0;

  die "Bad call type '${\ typeof $func}' for '$func'"
    unless isFunction($func);

  my $trace_name = func_trace($func) || func_name($func) || XXX $func;

  push @{$self->{stack}}, $self->new_state($trace_name);

  $self->trace('?', $trace_name, $args);

  my $pos = $self->{pos};
  $self->receive($func, 'try', $pos);

  my $func2 = $func->($self, @$args);
  my $value = $func2;
  while (isFunction($func2) or isArray($func2)) {
    $value = $func2 = $self->call($func2);
  }

  die "Calling '$trace_name' returned '${\ typeof($value)}' instead of '$type'"
    if $type ne 'any' and typeof($value) ne $type;

  if ($type ne 'boolean') {
    pop @{$self->{stack}};
    return $value;
  }

  if ($value) {
    $self->trace('+', $trace_name);
    $self->receive($func, 'got', $pos);
  }
  else {
    $self->trace('x', $trace_name);
    $self->receive($func, 'not', $pos);
  }

  pop @{$self->{stack}};

  return $value;
}
my %receivers;
sub receive {
  my ($self, $func, $type, $pos) = @_;

  my $receiver = ($receivers{$func} //=
    $self->make_receivers)->{$type};

  return unless $receiver;

  $receiver->($self->{receiver}, {
    text => substr($self->{input}, $pos, $self->{pos}-$pos),
    state => $self->state,
    start => $pos,
  });
}

sub make_receivers {
  my ($self) = @_;
  my $i = @{$self->{stack}};
  my $names = [];
  my $n;
  while ($i > 0 and ($n = $self->{stack}[--$i]{name}) !~ /_/) {
    if ($n =~ /^chr\((.)\)$/) {
      $n = 'chr_' . sprintf("%x", ord($1));
    }
    unshift @$names, $n;
  }
  my $name = join '__', $n, @$names;

  return {
    try => $self->{receiver}->can("try__$name"),
    got => $self->{receiver}->can("got__$name"),
    not => $self->{receiver}->can("not__$name"),
  };
}

# Match all subrule methods:
sub all {
  my ($self, @funcs) = @_;
  name 'all', sub {
    my $pos = $self->{pos};
    for my $func (@funcs) {
      if (not defined $func) {
        XXX '*** Missing function in @all group:', \@funcs;
      }

      if (not $self->call($func)) {
        $self->{pos} = $pos;
        return false;
      }
    }

    return true;
  };
}

# Match any subrule method. Rules are tried in order and stops on first match:
sub any {
  my ($self, @funcs) = @_;
  name 'any', sub {
    for my $func (@funcs) {
      if ($self->call($func)) {
        return true;
      }
    }

    return false;
  };
}

# Repeat a rule a certain number of times:
sub rep {
  my ($self, $min, $max, $func) = @_;
  name 'rep', sub {
    my $count = 0;
    my $pos = $self->{pos};
    while ($self->{pos} < $self->{len} and $self->call($func)) {
      return true if $min == 0 and $pos == $self->{pos};
      $count++;
    }
    if ($count >= $min and ($max == 0 or $count <= $max)) {
      return true;
    }
    else {
      $self->{pos} = $pos;
      return false;
    }
  }, "rep($min,$max)";
}

# Call a rule depending on state value:
sub case {
  my ($self, $var, $map) = @_;
  name 'case', sub {
    my $rule = $map->{$var} or
      XXX "Can't find '$var' in:", $map;
    $self->call($rule);
  }, "case($var, ${\ stringify $map})";
}

# Call a rule depending on state value:
sub flip {
  my ($self, $var, $map) = @_;
  my $value = $map->{$var} or
    XXX "Can't find '$var' in:", $map;
  return $value if not ref $value;
  return $->call($value);
}
name 'flip', \&flip;

# Match a single char:
sub chr {
  my ($self, $char) = @_;
  name 'chr', sub {
    if ($self->{pos} >= $self->{len}) {
      return false;
    }
    elsif (substr($self->{input}, $self->{pos}, 1) eq $char) {
      $self->{pos}++;
      return true;
    }
    else {
      return false;
    }
  }, "chr(${\ stringify($char)})";
}

# Match a char in a range:
sub rng {
  my ($self, $low, $high) = @_;
  name 'rng', sub {
    if ($self->{pos} >= $self->{len}) {
      return false;
    }
    elsif (
      $low le substr($self->{input}, $self->{pos}, 1) and
      substr($self->{input}, $self->{pos}, 1) le $high
    ) {
      $self->{pos}++;
      return true;
    }
    else {
      return false;
    }
  }, "rng(${\ stringify($low)},${\ stringify($high)})";
}

# Must match first rule but none of others:
sub but {
  my ($self, @funcs) = @_;
  name 'but', sub {
    my $pos1 = $self->{pos};
    return false unless $self->call($funcs[0]);
    my $pos2 = $self->{pos};
    $self->{pos} = $pos1;
    for my $func (@funcs[1..$#funcs]) {
      if ($self->call($func)) {
        $self->{pos} = $pos1;
        return false;
      }
    }
    $self->{pos} = $pos2;
    return true;
  }
}

sub chk {
  my ($self, $type, $expr) = @_;
  name 'chk', sub {
    my $pos = $self->{pos};
    $self->{pos}-- if $type eq '<=';
    my $ok = $self->call($expr);
    $self->{pos} = $pos;
    return $type eq '!' ? not($ok) : $ok;
  }, "chk($type, ${\ stringify $expr})";
}

sub set {
  my ($self, $var, $expr) = @_;
  name 'set', sub {
    $self->state->{$var} = $self->call($expr, 'any');
    return true;
  };
}

sub max {
  my ($self, $max) = @_;
  name 'max', sub {
    return true;
  };
}

sub exclude {
  my ($self, $rule) = @_;
  name 'exclude', sub {
    return true;
  };
}

sub add {
  my ($self, $x, $y) = @_;
  name 'add', sub {
    return $x + $y;
  }, "add($x,$y)";
}

sub sub {
  my ($self, $x, $y) = @_;
  name 'sub', sub {
    return $x - $y;
  }, "sub($x,$y)";
}

sub m {0}
sub t {''}

#------------------------------------------------------------------------------
# Special grammar rules
#------------------------------------------------------------------------------
sub start_of_line {
  (
    $_[0]->{pos} == 0 ||
    substr($_[0]->{input}, $_[0]->{pos} - 1, 1) eq "\n"
  ) ? true : false;
}
name 'start_of_line', \&start_of_line;

sub end_of_stream {
  ($_[0]->{pos} >= $_[0]->{len}) ? true : false;
}
name 'end_of_stream', \&end_of_stream;

sub empty { true }
name 'empty', \&empty;

sub auto_detect_indent {
  1;
}
name 'auto_detect_indent', \&auto_detect_indent;

#------------------------------------------------------------------------------
# Trace debugging
#------------------------------------------------------------------------------
sub noop {}
sub trace_func {
  my ($self, $type, $call, $args) = @_;
  $args //= [];

  my $level = $self->state->{lvl};
  my $indent = ' ' x $level;
  if ($level > 0) {
    my $l = length "$level";
    $indent = "$level" . substr($indent, $l);
  }

  my $input = substr($self->{input}, $self->{pos});
  $input =~ s/\t/\\t/g;
  $input =~ s/\r/\\r/g;
  $input =~ s/\n/\\n/g;

  my $line = sprintf(
    "%s%s %-30s  %4d '%s'\n",
    $indent,
    $type,
    $self->trace_format_call($call, $args),
    $self->{pos},
    $input,
  );

  my $trace_info = undef;
  $level = "${level}_$call";
  if ($type eq '?' and not $self->{trace_off}) {
    $trace_info = [$type, $level, $line];
  }
  if (grep $_ eq $call, @{$self->trace_no_descend}) {
    $self->{trace_off} += $type eq '?' ? 1 : -1;
  }
  if ($type ne '?' and not $self->{trace_off}) {
    $trace_info = [$type, $level, $line];
  }

  if (defined $trace_info) {
    my ($prev_type, $prev_level, $prev_line) = @{$self->{trace_info}};
    if ($prev_type eq '?' and $prev_level eq $level) {
      $trace_info->[1] = '';
      if ($line =~ /^\d*\ *\+/) {
        $prev_line =~ s/\?/=/;
      }
      else {
        $prev_line =~ s/\?/!/;
      }
    }
    if ($prev_level) {
      warn sprintf "%5d %s", $self->{trace_num}++, $prev_line;
    }

    $self->{trace_info} = $trace_info;
  }
}

sub trace_format_call {
  my ($self, $call, $args) = @_;
  return $call unless @$args;
  my @list = map {
    if (isFunction($_)) {
      $_->();
    }
    elsif (not defined $_) {
      'null';
    }
    else {
      $_;
    }
  } @$args;
  return $call . '(' . join(',', @list) . ')';
}

sub trace_flush {
  my ($self) = @_;
  if (my $line = $self->{trace_info}[2]) {
    warn sprintf "%5d %s", $self->{trace_num}++, $line;
  }
}

sub trace_no_descend {
  [
#     'l_document_prefix',
#     'l_directive_document',
#     'l_explicit_document',
#     's_l_block_in_block',
#     's_separate',
#     'c_ns_alias_node',
#     'ns_plain',
#     's_l_comments',
#     'c_ns_properties',
#     'ns_flow_pair',

#     'c_printable',
#     'b_char',
#     'c_byte_order_mark',
#     'nb_char',
#     'ns_char',
#     'c_indicator',
#     'ns_plain_char',
#     's_white',
#     'c_flow_indicator',
#     'l_comment',
#     's_l_block_collection',
  ];
}

1;

# vim: sw=2:
