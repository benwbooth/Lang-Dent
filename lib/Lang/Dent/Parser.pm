package Lang::Dent::Parser;

# TODO: parser, macro expander, code generator, self-hosting
# implementation, repl

use Data::Dumper qw(Dumper);
use List::Util qw(min);

use JSON;

use base 'Lang::Dent::Reparse';

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

my $json = JSON->new->allow_nonref;
sub meta { ref($_[0])? $json->decode(ref($_[0])) : {} }
sub with_meta { $_[1]? bless($_[0], $json->encode($_[1])) : $_[0] }
sub merge_meta { with_meta($_[0], {%{meta($_[0])}, %{$_[1]||{}}}) }
sub type { meta($_[0])->{type} }

sub document {
  my ($self) = @_;
  my $lists = [map {@$_} @{$self->many(indentedList(''))}];
  my $comment = $self->option(\&comment);
  with_meta(
    [(map {@$_} @$lists), defined($comment)?$commment:()], 
    {type=>'Document', defined($comment)?(comment=>$comment):()});
}

sub indent {
  my ($self) = @_;
  $self->{indent} = defined($self->{indent})? $self->{indent} : $self->match(qr/^[ \t]*/);
}

sub comment {
  my ($self) = @_;

  # try to parse literate comments or regular comments
  my $indent = $self->produce(\&indent);
  my $comment = $self->{literate} && length($indent) == 0
    ? $self->match(qr/^[^\n]*/) : $self->option(qr/^#[^\n]*/);
  # try to parse a newline
  my $eol = $self->option(qr/^\n/);

  $self->fail if !defined($comment) && !defined($eol);

  my $comments = join('', grep {defined} ($comment,$eol));
  $self->{indent} = undef;
  $comments;
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
    $self->fail if $self->eof || length($indent) <= length($parent_indent);
    $self->{indent} = undef;

    my $tokenLine = $self->produce(\&tokenLine);
    my $sublists = [ map {@$_} @{$self->many(sub {$_[0]->indentedList($indent)})} ];

    [ @tokens == 1 && @$sublists == 0? 
        merge_meta($tokens[0],
          {defined($comments)?(comments=>$comments):()}) : 
        process_listops(with_meta([@tokens, map {@$_} @$sublists], 
          {type=>'List', defined($comments)?(comments=>$comments):()}))
    ];
  };
}

sub comma {
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

sub semicolon {
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

sub colon {
  my ($list) = @_;
  my $newlist = with_meta([], meta($list));
  for my $i (0..$#$list) {
    my $element = $list->[$i];
    if (type($element) eq 'String' && $$element eq ':' && meta($element)->{bareword}) {
      push @$newlist, colon(with_meta([@$list[$i+1..$#$list]], {type=>'List'}));
    } 
    else {
      push @$newlist, $element; 
    }
  }
  $newlist;
}

sub process_listops {
  my ($list) = @_;
  map {colon($_)} map {semicolon($_)} map {comma($_)} ($list);
}

sub linecomment {
  my ($self) = @_;
  $self->match(qr/^#[^\n]*/);
}

sub tokenLine {
  my ($self) = @_;
  $self->choice(
    \&indentedString,
    sub {
      my ($self) = @_;
      my $tokens = $self->sepEndBy1(\&token, qr/^[ \t\r]+/);
      my $linecomment = $self->option(\&linecomment);
      merge_meta($tokens->[-1], {linecomment=>$linecomment}) if defined $linecomment;
      $tokens;
    });
}

sub token {
  my ($self) = @_;
  $self->choice(
    \&reflist,
    \&collectingList,
    infixList('List'),
    list(qr/^\(/, qr/^\)/, 'List'),
    list(qr/^\[/, qr/^\]/, 'QuotedList'),
    \&number,
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
      $self->fail if $self->eof;
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
  my $list = $self->produce(list(qr/^\[/,qr/^\]/,'QuotedList'));
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

sub indentedString {
  my ($self) = @_;
  $self->match(qr/^<<<[ \t\r]*\n/);

  my $parent_indent = $self->produce(\&indent);
  my $string = join('', map {@$_} ($self->many(sub {
    my ($self) = @_;
    # parse indentation
    my $indent = $self->produce(\&indent);
    my $indent_length = min(length($parent_indent),length($indent));
    die("Inconsistent whitespace usage in indentation") 
      if substr($indent,0,$indent_length) ne substr($parent_indent,0,$indent_length);
    # check if this is a blank line, those do not end the string.
    my $eol = $self->option(qr/^\n/);
    $self->fail if !defined($eol) && (length($indent) < length($parent_indent) || length($indent) == 0);
    $self->{indent} = undef;
    defined($eol)? join('',substr($indent,$indent_length), $eol) : $self->match(qr/^[^\n]*\n/);
  })));
  with_meta($string, {type=>'String'});
}

sub infix {
  my ($list) = @_;
  @$list <= 1? $list : 
    with_meta([@list[1,0], @{infix(with_meta([@$list[2..$#list]], meta($list)))}], meta($list));
}

sub infixList {
  my ($type) = @_;
  sub {
    my ($self) = @_;
    my $list = $self->produce(list(qr/^\{/, qr/^\}/, $type));
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
    my $list = $self->option($self->choice(
        list(qr/^\(/, qr/^\)/, 'List'),
        infixList('InfixList'),
      ));
    if ($list && type($list) eq 'List') {
      unshift @$list, $result;
      return $list;
    }
    if ($list && type($list) eq 'InfixList') {
      return with_meta([$result, merge_meta($list, {type=>'List'})], {type=>'List'});
    }
    $result;
  };
}

sub symbol {
  my ($self) = @_;
  my $sigil = $self->match(qr/^[\$\@\%\&\*:]/);
  my $name = $self->option(sub {$_[0]->choice(string('"'), string("'"), \&bareWord)});
  defined($name)? 
    with_meta($name, {type=>'Symbol', sigil=>$sigil}) :
    with_meta($sigil, {type=>'String'});
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

