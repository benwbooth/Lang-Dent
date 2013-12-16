package Lang::Dent::Parser;
use Lang::Dent::Meta qw(:all);

# TODO: macro expander, code generator, self-hosting
# implementation, repl

use Data::Dumper qw(Dumper);
use List::Util qw(min);

use JSON;

use parent 'Lang::Dent::Reparse';

sub new {
  my ($class, %options) = @_;
  my $self = $class->SUPER::new;
  $self->{$_} = $options{$_} for keys %options;
  bless $self, $class;
}

sub parse {
  my ($self, $data) = @_;
  $self->set_input($data=~/\n$/?$data:$data."\n");
  $self->start(\&document);
}

sub document {
  my ($self) = @_;
  my $lists = [map {@$_} @{$self->sepEndBy(indentedList(''), \&blanklines)}];
  my $comment = $self->option(\&comment);
  with_meta(
    [(map {@$_} @$lists), defined($comment)?$commment:()], 
    {type=>'Document', defined($comment)?(comment=>$comment):()});
}

sub blankline {
  my ($self) = @_;
  $self->produce(\&indent);
  $self->match(qr/^\n/);
}
sub blanklines {
  my ($self) = @_;
  $self->many(\&blankline);
}

sub indent {
  my ($self) = @_;
  $self->{indent} = defined($self->{indent})? $self->{indent} : $self->match(qr/^[ \t]*/);
}

sub comment {
  my ($self) = @_;
  my $indent = $self->produce(\&indent);
  my $comment = $self->produce(qr/^#([^\n]*\n)/);
  $self->fail if !defined($comment);
  $self->{indent} = undef;
  $comment;
}

sub pod {
  my ($self) = @_;
  join('', 
    $self->match(qr/^=[^\n]*\n/),
    $self->many(qr/^(?!=cut\n)[^\n]*\n/),
    $self->match(qr/^=cut\n/),
  );
}

sub comments {
  my ($self) = @_;
  join('',@{$self->many1(sub {$_[0]->choice(\&pod, \&comment)})||[]});
}

sub indentedList {
  my ($self,$parent_indent) = @_;
  sub {
    my $comments = $self->option(\&comments);
    my $indent = $self->produce(\&indent);
    # check for whitespace consistency
    my $indent_length = min(length($parent_indent),length($indent));
    die("Inconsistent whitespace usage in indentation") 
      if substr($indent,0,$indent_length) ne substr($parent_indent,0,$indent_length);
    # dedent
    $self->fail if length($indent) <= length($parent_indent);
    $self->{indent} = undef;

    my $tokenLine = $self->produce(\&tokenLine);
    # assume unindented lines terminate at eol for interactive mode
    my $sublists = length($indent)>0? 
      [ map {@$_} @{$self->many(sub {$_[0]->indentedList($indent)})} ] : [];

    [ @tokens == 1 && @$sublists == 0? 
        merge_meta($tokens[0],
          {defined($comments)?(comments=>$comments):()}) : 
        listOps(with_meta([@tokens, map {@$_} @$sublists], 
          {type=>'List', defined($comments)?(comments=>$comments):()}))
    ];
  };
}

sub quotedListOp {
  my ($list) = @_;
  if (@$list && type($list->[0]) eq 'String' && meta($list->[0])->{bareword}) {
    if (${$list->[0]} eq '`') {
      return with_meta([@$list[1..$#$list]], {%{meta($list)}, quoted=>'true'});
    } 
    elsif (${$list->[0]} eq '~') {
      return with_meta([@$list[1..$#$list]], {%{meta($list)}, quoted=>'false'});
    }
  }
  $list;
}

sub commaListOp {
  my ($list) = @_;
  my $newlist = with_meta([], meta($list));
  for my $element (@$list) {
    if (type($element) eq 'List' && @$element && 
        type($element->[0]) eq 'String' && ${$element->[0]} eq ',' && meta($element->[0])->{bareword}) 
    {
      push @$newlist, @$element[1..$#$element];
      merge_meta($newlist, {
        linecomment=>join('',grep {defined} (meta($list)->{linecomment},meta($element)->{linecomment})),
        comments=>join('', grep {defined} (meta($list)->{comments},meta($element)->{comments})),
      });
    }
    else {
      push @$newlist, $element; 
    }
  }
  $newlist;
}

sub semicolonListOp {
  my ($list) = @_;
  my @lists = (with_meta([], meta($list)));
  for my $element (@$list) {
    if (type($element) eq 'String' && $$element eq ';' && meta($element)->{bareword}) {
      push @lists, with_meta([], {type=>'List'});
    }
    else {
      push @{$lists[-1]}, $element;
    }
  }
  @lists;
}

sub colonListOp {
  my ($list) = @_;
  my $newlist = with_meta([], meta($list));
  for my $i (0..$#$list) {
    my $element = $list->[$i];
    if (type($element) eq 'String' && $$element eq ':' && meta($element)->{bareword}) {
      push @$newlist, colonListOp(with_meta([@$list[$i+1..$#$list]], {type=>'List'}));
    } 
    else {
      push @$newlist, $element; 
    }
  }
  $newlist;
}

sub listOps {
  my ($list) = @_;
  map {quotedListOp($_)} map {colonListOp($_)} map {semicolonListOp($_)} map {commaListOp($_)} ($list);
}

sub linecomment {
  my ($self) = @_;
  $self->match(qr/^#[^\n]*/);
}

sub tokenLine {
  my ($self) = @_;
  my $tokens = $self->sepEndBy1(\&token, qr/^[ \t\r]+/);
  my $linecomment = $self->option(\&linecomment);
  merge_meta($tokens->[-1], {linecomment=>$linecomment}) if defined $linecomment;
  $tokens;
}

sub token {
  my ($self) = @_;
  $self->choice(
    \&reflist,
    \&collectingList,
    infixList(list(qr/^\{/, qr/^\}/, 'List')),
    list(qr/^\(/, qr/^\)/, 'List'),
    list(qr/^\[/, qr/^\]/, 'ArrayList'),
    \&number,
    \&multilineString,
    neoteric(string('"')),
    neoteric(string("'")),
    neoteric(\&symbol),
    neoteric(\&bareWord),
  );
}

sub list {
  my ($left, $right, $type) = @_;
  sub {
    my ($self) = @_;
    $self->match($left);
    my $tokenLine = $self->option(\&tokenLine);
    my $eol = $self->option(qr/^\n/);
    my $moreLines = defined($eol)? $self->many(sub {
      my ($self) = @_;
      my $comments = $self->option(\&comments);
      my $tokenLine = $self->produce(\&tokenLine);
      $self->option(qr/^\n/);
      merge_meta($tokenLine->[0], {comments=>$comments}) if defined $comments;
      $tokenLine;
    }) : [];
    $self->match($right);
    with_meta([ @$tokenLine, map {@$_} @$moreLines], {type=>$type});
  };
}

sub reflist {
  my ($self) = @_;
  $self->match(qr/^(?=[\@\&\%]\[)/);
  my $sigil = $self->match(qr/^[\@\&\%]/);
  my $list = $self->produce(list(qr/^\[/,qr/^\]/,'ArrayList'));
  merge_meta($list, {
      type=>$sigil eq '@'? 'ArrayList' :
            $sigil eq '&'? 'CodeList' : 
            $sigil eq '%'? 'HashList' : 
            'List'});
}

sub collectingList {
  my ($self) = @_;
  $self->match(qr/^\*\[[ \t\r]*/);
  my $tokenLine = $self->option(\&tokenLine);
  # save the indent value
  my $indent = $self->{indent};
  $self->{indent} = undef;
  my $lists = $self->option(sub {$_[0]->match(qr/^\n/); $_[0]->produce(\&document)});
  $self->match(qr/^\]/);
  $self->{indent} = $indent;
  with_meta([defined($tokenLine)?@$tokenLine:(), @$lists], {%{meta($lists)}, type=>'List'});
}

sub multilineStringLine {
  my ($self) = @_;
  my $indent = $self->produce(\&indent);
  my $line = $self->produce(qr/^\^([^\n]*\n)/);
  $self->fail if !defined($line);
  $self->{indent} = undef;
  $line;
}

sub multilineString {
  my ($self) = @_;
  my $string = join('', @{$self->many1(\&multilineStringLine)});
  with_meta($string, {type=>'String'});
}

sub infix {
  my ($list) = @_;
  @$list <= 1? $list : 
    with_meta([@list[1,0], @{infix(with_meta([@$list[2..$#list]], meta($list)))}], meta($list));
}

sub infixList {
  my ($list) = @_;
  sub {
    my ($self) = @_;
    return $list if @$list==0 || @$list == 2;
    return $list[0] if @$list == 1;
    die "Even number of elements in infix list" if @$list % 2 == 0;
    infix($list);
  };
}

sub neoteric {
  my ($parser) = @_;
  sub {
    my ($self) = @_; 
    my $result = $self->produce($parser);
    my $next = $self->option(sub {$_[0]->choice(
        list(qr/^\(/, qr/^\)/, 'List'),
        infixList('InfixList'),
        \&multilineString,
        neoteric(string('"')),
        neoteric(string("'")),
      )});
    if ($next && type($next) eq 'List') {
      unshift @$next, $result;
      return $next;
    }
    elsif ($next && type($next) eq 'InfixList') {
      return with_meta([$result, merge_meta($next, {type=>'List'})], {type=>'List'});
    }
    elsif ($next) {
      return with_meta([$result, $next], {type=>'List'});
    }
    $result;
  };
}

sub symbol {
  my ($self) = @_;
  my $sigil = $self->match(qr/^~?(?:[:]|[\\\$\@\%\&\*]+)/);
  my $unquote = $sigil =~ s/^~//;
  my $label = $self->option(sub {$_[0]->choice(string('"'), string("'"), \&bareWord)});
  my $name = $sigil.(defined($label)? $label : '');
  my $result = with_meta($name, {type=>'Symbol', $unquote?(quoted=>'false'):()});
}

sub bareWord {
  my ($self) = @_;
  my $word = $self->match(qr/^[^#\[\]{}() \t\r\n][^\[\]{}() \t\r\n]*/);
  with_meta($word, {type=>'String', bareword=>'true'});
}

sub string {
  my ($delim) = @_;
  sub {
    my ($self) = @_;
    $self->match(qr/^\Q$delim\E/);
    my $str = $self->match(qr/^(?:(?!\Q$delim\E).|\Q$delim\E\Q$delim\E)*/); 
    $self->match(qr/^\Q$delim\E/);
    $str =~ s/\Q$delim\E\Q$delim\E/\Q$delim\E/g;
    with_meta($str, {type=>'String'});
  };
}

# Numeric literals
sub number {
  my ($self) = @_;
  my $plus_minus = $self->option(qr/^[+-]/,'');
  my $number = $self->choice(\&zeroNum, \&decimal);
  with_meta($plus_minus eq '-'? -$number : $number, {type=>'Number'});
}
sub zeroNum {
  my ($self) = @_;
  $self->match(qr/^(?=0)/);
  $self->choice(\&hex, \&oct, \&binary, \&decimal);
}
sub decimal {
  my ($self) = @_;
  $self->match(qr/^\d+(?:\.\d+)?(?:[eE][\+\-]?\d+)?/);
}
sub hex {
  my ($self) = @_;
  CORE::hex($self->match(qr/^0x([0-9a-f]+)/i)); 
}
sub oct {
  my ($self) = @_;
  CORE::oct($self->match(qr/^0o([0-7]+)/i)); 
}
sub binary {
  my ($self) = @_;
  # CORE::oct can also parse binary
  CORE::oct($self->match(qr/^0b[01]+/i)); 
}

1;

