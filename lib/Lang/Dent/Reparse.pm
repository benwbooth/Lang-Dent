package Lang::Dent::Reparse;
use strict;
use warnings;

sub new {
  my ($class, $input) = @_;
  bless {
    input=>$input,
    line=>undef,
    col=>undef,
    filename=>undef,
    token=>undef,
  }, $class;
}

sub eof {
  my ($self) = @_;
  ref($self->{input}) eq 'ARRAY'? @{$self->{input}} == 0 : length($self->{input}) == 0;
}

=head2 fail

Indicate failure, optionally resetting the input to a previous
state.

=cut 

sub fail {
  my ($self, $state) = @_;
  %$self = %$state if defined($state); 
  die \&fail;
}

=head2 produce

Execute a production, which could be a function or a RegExp.

=cut

sub produce {
  my ($self, $method) = @_;
  ref($method) eq 'Regexp'? $self->match($method) : $method->($self);
}

=head2 start

Begin parsing using the given production, return the result.  All
input must be consumed.

=cut

sub start {
  my ($self, $method) = @_;
  my $val = eval {
    my $val = $self->produce($method); 
    $self->die("Expected end of file") if !$self->eof;
    $val;
  };
  if ($@) {
    $self->die("$@") if $@ ne \&fail;
    $self->die("Could not parse input");
  }
  $val;
}

sub die {
  my ($message) = @_;
  die "$message"
    .(defined($self->{filename})?
      " in \"$self->{filename}\"":"")
    .(defined($self->{token})?
      " at token ".($self->{token}+1) : "")
    .(defined($self->{line}) || defined($self->{col})?
      " at line ".(($self->{line}||0)+1).", column ".(($self->{col}||0)+1)."." : "");
}

=head2 maybe

Try to produce a value from method.  If it fails, restore the input
to its previous state.

=cut

sub maybe {
  my ($self, $method) = @_;
  # make a shallow copy of the parser state
  my $state = {%$self, input=>ref($self->{input}) eq 'ARRAY'? [@{$self->{input}}] : $self->{input}};
  my $result = eval { $self->produce($method); };
  if ($@) {
    $self->die($@) if $@ ne \&fail;
    $self->fail($state);
  }
  $result;
}

=head2 option

If the production method fails, don't fail, just return otherwise.

=cut

sub option {
  my ($self, $method, $otherwise) = @_;
  my $val = eval { $self->maybe($method); };
  if ($@) {
    $self->die($@) if $@ ne \&fail;
    return $otherwise;
  }
  $val;
}

=head2

Succeed if the production fails, and vice-versa.

=cut

sub not {
  my ($self, $method) = @_;
  eval { $self->produce($method); };
  $self->die("Unexpected input") if !$@;
  1;
}

=head2 between

Return the value produced by body.  This is equivalent to
seq(left, body, right)[0].

=cut

sub between {
  my ($self, $left, $right, $body) = @_;
  my $val = eval {
    $self->produce($left);
    my $val = $self->produce($body);
    $self->produce($right);
    return $val;
  };
  if ($@) {
    $self->die($@) if $@ ne \&fail;
    return $self->fail;
  }
  $val;
}

=head2 match

Match a regular expression, returning the first captured group or
the matched string. Only works with string input.

=cut

sub match {
  my ($self, $pattern) = @_;
  my @probe = $self->{input} =~ /$pattern/;
  return $self->fail if !@probe; 

  $self->{line} = ($self->{line}||0) + length($probe[0]=~/\n/g);
  $self->{col} = length($probe[0]=~/[^\n]*$/);
  $self->{input} = substr($self->{input}, length($probe[0]));
  !defined($probe[1])? $probe[0] : $probe[1];
}

=head2 satisfy

See if the next token passes the satisfy function. 
Works with both string and list input.

=cut

sub satisfy {
  my ($self, $sub) = @_;
  if (ref($self->{input}) eq 'ARRAY') {
    my $token = $self->{input}[0];
    my $val = eval { $sub->($self, $token) };
    if ($@) {
      $self->die($@) if $@ ne \&fail;
      return $self->fail;
    }
    splice($self->{input},0,1); 
    $self->{token}++;
    return $val;
  }

  my $token = substr($self->{input},0,1);
  my $val = eval { $sub->($self, $token) };
  if ($@) {
    $self->die($@) if $@ ne \&fail;
    return $self->fail;
  }
  $self->{input} = substr($self->{input},1);
  $token eq "\n"? do { $self->{line}++; $self->{col}=0 } : $self->{col}++;
  $val;
}

=head2 choice

Return the result of the first production that matches.

=cut

sub choice {
  my ($self, @arguments) = @_;
  for my $argument (@arguments) {
    my $val = eval { $self->produce($argument); }; 
    if ($@) {
      $self->die($@) if $@ ne \&fail;
      return $self->fail;
    }
    return $val;
  }
}

=head2 seq

Match every production in a sequence, returning a list of the
values produced.

=cut

sub seq {
  my ($self, @arguments) = @_;
  my $val = [];
  my $input = $self->{input};

  eval {
    for my $argument (@arguments) {
      push @$val, $self->produce($argument); 
    }
  };
  return $self->fail if $@;
  $val;
}

=head2 skip

Skip zero or more instances of method.  Return the parser.

=cut

sub skip {
  my ($self, $method, $min) = @_;
  my $found = 0;

  while (!$self->eof) {
    eval {
      $self->maybe($method);
      $found++;
    }; 
    if ($@) {
      $self->die($@) if $@ ne \&fail;
      last;
    }
  }
  $min && $found < $min? $self->fail : $self;
}

sub skip1 {
  my ($self, $method) = @_;
  $self->skip($method, 1);
}

=head2 many

Return a list of zero or more productions.

=cut

sub many {
  my ($self, $method, $min) = @_;
  my $result = [];
  while (!$self->eof) {
    eval { push @$result, $self->maybe($method); }; 
    if ($@) {
      $self->die($@) if $@ ne \&fail;
      last;
    }
  }
  $min && @$result < $min? $self->fail : $result;
}

sub many1 {
  my ($self, $method) = @_;
  return $self->many($method, 1);
}

=head2 sepBy

Return the array of values produced by method with sep between each
value.

=cut

sub sepBy {
  my ($self, $method, $sep, $min) = @_;
  my $result = [];
  eval {
    push @$result, $self->produce($method);
    while (!$self->eof) {
      eval {
        $self->produce($sep);
        push @$result, $self->produce($method);
      }; 
      if ($@) {
        $self->die($@) if $@ ne \&fail;
        $self->fail;
      }
    }
  };
  if ($@) {
    $self->die($@) if $@ ne \&fail;
  }
  $min && @$result < $min? $self->fail : $result;
}

sub sepBy1 {
  my ($self, $method, $sep) = @_;
  $self->sepBy($method, $sep, 1);
}

=head2 endBy

Return the array of values produced by method.  The series must be
terminated by end.

=cut

sub endBy {
  my ($self, $method, $end, $min) = @_;
  my $val = $self->many($method, $min);
  $self->option($end);
  $val;
}

sub endBy1 {
  my ($self, $method, $end) = @_;
  $self->endBy($method, $end, 1);
}

=head2 sepEndBy

Return the array of values produced by method with sep between each
value.  The series may be terminated by a sep.

=cut

sub sepEndBy {
  my ($self, $method, $sep, $min) = @_;
  my $val = $self->sepBy($method, $sep, $min);
  $self->option($sep);
  $val;
}

sub sepEndBy1 {
  my ($self, $method, $sep) = @_;
  $self->sepEndBy($method, $sep, 1);
}

sub chainl {
  my ($self, $method, $op, $otherwise, $min) = @_;
  my $found = 0;
  my $result = $otherwise;

  eval {
    $result = $self->maybe($method);
    $found++;
    while (!$self->eof) {
      eval {
        $result = $self->produce($op)->($result, $self->produce($method));
        $found++;
      }; 
      if ($@) {
        $self->die($@) if $@ ne \&fail;
        $self->fail;
      }
    }
  };
  if ($@) {
    $self->die($@) if $@ ne \&fail;
  }
  $min && $found < $min? $self->fail : $result;
}

sub chainl1 {
  my ($self, $method, $op) = @_;
  $self->chainl($method, $op, undef, 1);
}

1;

