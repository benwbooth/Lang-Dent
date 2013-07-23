=head1 NAME

Lang::Dent - 

=head1 SYNOPSIS

  use Lang::Dent;

=head1 DESCRIPTION

=head2 EXPORT

None by default.

=head1 AUTHOR

Ben Booth, E<lt>benwbooth@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by Ben Booth

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.14.4 or,
at your option, any later version of Perl 5 you may have available.

=cut

package Lang::Dent;
use Lang::Dent::Parser;
use File::Spec::Functions qw(catdir);
use strict;
use warnings;

no strict 'refs';

require Exporter;

our $VERSION = '0.01';

our @ISA = qw(Exporter);
our %EXPORT_TAGS = ( 'all' => [ qw( use ) ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = qw( );

sub module2file {
  my ($module, $suffix) = @_;
  catdir(split /::/,$module).$suffix;
}

sub search {
  my ($file) = @_;
  for my $inc (@INC) {
    my $path = catdir($inc,$file);
    return $path if -f $path;
  }
  undef;
}

sub use {
  my $module = shift or return;
  my $version = shift if !ref($_[0]);
  my $list = shift if ref($_[0]);

  my $file = module2file($module, '.dent');
  my $pmfile = module2file($module, '.pm');

  if (!exists $INC{$pmfile}) {
    my $path = search($file);
    die "Could not find file $file" if !defined $path;
    # read the entire file to a string
    open (my $fh, '<', $path)
      or die "Could not read file $path: $!";
    my $text = do {local $/; <$fh>};
    close $fh;
    # parse into list structure
    my $parser = Lang::Dent::Parser->new;
    my $parsed = $parser->parse($text);
    # load dependencies and expand macros
    my $expander = Lang::Dent::Expander->new;
    my $expanded = $expander->expand($parsed);
    # transform into perl source code
    my $compiler = Lang::Dent::Compiler->new;
    my $compiled = $compiler->compile($expanded);
    # eval the perl code
    my @return = eval $compiled or die "Module $file did not return true";
    die $@ if $@;
    { package [caller]->[0];
      $module->import(@$list);
    }
    $INC{$pmfile} = $path;
    return wantarray? @return : $return[0];
  }
  1;
}

1;

