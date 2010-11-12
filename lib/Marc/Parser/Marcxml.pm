package Marc::Parser::Marcxml;
# ABSTRACT: Parser for MARXML Marc records

use namespace::autoclean;
use Moose;

extends 'Marc::Parser';

use Marc::Field::Control;
use Marc::Field::Std;
use XML::Simple;

has 'xs' => ( is => 'rw', default => sub {  XML::Simple->new() } );


override 'parse' => sub {
    my ($self, $raw) = @_;

    return unless $raw;

    my $ref = eval { $self->xs->XMLin($raw, forcearray => [ 'subfield' ] ) };
    return undef if $@;

    $raw =~ s/\n//g;
    $raw =~ s/>\s*</></g;
    my @parts = split />/, $raw;
    my ($tag, $code, $ind1, $ind2);
    my $record = Marc::Record->new();
    my @fields;
    while ( @parts ) {
        $_ = shift @parts;
        $_ = shift @parts if /^<record/;
        if ( /^<leader/ ) {
            $_ = shift @parts;
            s/<\/leader//;
            $record->_leader($_);
            next;
        }
        if ( /^<controlfield/ ) {
            my ($tag) = /tag="(.*)"/;
            $_ = shift @parts;
            s/<\/controlfield//;
            push @fields, Marc::Field::Control->new( tag => $tag, value => $_ );
            next;
        }
        if ( /^<datafield/ ) {
            my ($tag, $ind1, $ind2) = /tag="(.*?)"\s*ind1="(.*?)"\s*ind2="(.*)"/;
            my @subf;
            while ( @parts && $parts[0] =~ /^<subfield.*code="(.*)"/ ) {
                my $letter = $1;
                shift @parts;
                $_ = shift @parts;
                s/<\/subfield//;
                push @subf, [ $letter => $_ ];
            }
            push @fields, Marc::Field::Std->new(
                tag => $tag,
                ind1 => $ind1,
                ind2 => $ind2,
                subf => \@subf );
            shift @parts;
            next;
        }
        last;
    }
    $record->fields( \@fields );

    return $record;
};

__PACKAGE__->meta->make_immutable;

1;

=head1 SEE ALSO
=for :list
* L<Marc>
* L<Marc::Parser>
