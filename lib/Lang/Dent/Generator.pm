package Lang::Dent::Generator;
use Lang::Dent::Meta qw(:all);
use strict;
use warnings;

sub new {
  my ($class, %options) = @_;
  my $self = $class->SUPER::new;
  $self->{$_} = $options{$_} for keys %options;
  bless $self, $class;
}

1;

