package Lang::Dent::Expander;
use Lang::Dent;
use Lang::Dent::Meta qw(:all);
use strict;
use warnings;
no strict 'refs';

sub new {
  my ($class, %options) = @_;
  my $self = $class->SUPER::new;
  $self->{$_} = $options{$_} for keys %options;
  bless $self, $class;
}

sub expand {
  my ($self, $parsed, $package, $macros, $level) = @_;
  $package = 'main' if !defined $package;
  $macros ||= {};
  $level ||= 0;

  my @expand;
  for my $list (grep {type($_) eq 'List'} @$parsed) {
    if (@$list) {
      my $head = $list->[0];
      # module import
      if (type($head) eq 'String' && meta($head)->{bareword} && $$head eq 'use') {
        &Lang::Dent::use(@$list[1..$#list]);
        push @expand, $list;
      }
      # package declaration
      elsif (type($head) eq 'String' && meta($head)->{bareword} && $$head eq 'package') {
        $package = &Lang::Dent::package(@$list[1..$#list]);
        push @expand, $list;
      }
      # macro definition
      elsif (type($head) eq 'String' && meta($head)->{bareword} && $$head eq 'macro') {
        my $macro = &Lang::Dent::sub(@$list[1..$#list]);
        $macros{meta($macro)->{name}} = $macro;
        push @expand, $list;
      }
      # macro application
      elsif (type($head) eq 'String' || type($head) eq 'Symbol') {
        my @output = eval { &$head(@$list[1..$#list]); };
        push @expand, @output if !$@;
      }
      else {
        push @expand, $list;
      }
    }
  }
  @$parsed = @expand;
}

1;

