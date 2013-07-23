package Lang::Dent::Meta;
use JSON;
use parent 'Exporter';
use strict; 
use warnings;

our %EXPORT_TAGS = ( 'all' => [ qw( meta with_meta merge_meta type ) ] );
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our $json = JSON->new->allow_nonref;

sub meta { ref($_[0])? $json->decode(ref($_[0])) : {} }
sub with_meta { $_[1]? bless($_[0], $json->encode($_[1])) : $_[0] }
sub merge_meta { with_meta($_[0], {%{meta($_[0])}, %{$_[1]||{}}}) }
sub type { meta($_[0])->{type} }

1;

