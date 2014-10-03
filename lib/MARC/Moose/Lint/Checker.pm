package MARC::Moose::Lint::Checker;
# ABSTRACT: A class to 'lint' biblio record based on a rules file

use Moose;
use Modern::Perl;
use YAML;


=attr file

Name of the file containing validation rules based on which a biblio record can
be validated.

=cut
has file => (is => 'rw');

has rules => (is => 'rw', isa => 'HashRef');

has table => (is => 'rw', isa => 'HashRef', default => sub { {} });



sub BUILD {
    my $self = shift;

    my $file = $self->file;
    unless (-f $file) {
        say "$file: isn't a file";
        exit;
    }
    open my $fh, "<", $file;
    my @rules;
    my @parts;
    my $linenumber = 0;
    my %rules;
    while (<$fh>) {
        $linenumber++;
        chop;
        s/ *$//;
        last if /^====/;

        if ( length($_) ) {
            push @parts, $_;
            next;
        }
        #say;
        my $tag = shift @parts;
        if ( $tag !~ /^([0-9]{3})[_|\+]*/ ) {
            say;
            say "Line $linenumber: Invalid tag portion";
            exit;
        }
        my $tag_digit = $1;
        my $is_control_field = $tag_digit lt '010';
        if ( (!$is_control_field && @parts < 3) || ($is_control_field && @parts > 1) ) {
            say;
            say "Line $linenumber: Invalid rule: wrong number of parts";
            exit;
        }
        my @rule = (
            $tag_digit,
            $tag =~ /_/ ? 1 : 0,
            $tag =~ /\+/ ? 1 : 0
        );

        if ( $is_control_field ) {
            push @rule, shift @parts;
        }
        else {
            push @rule, [ shift @parts, shift @parts ],
            [ map {
                s/^ *//; s/ *$//;
                my ($letter, $table, $regexp) =
                    /^([a-zA-Z0-9+_]+)\@([A-Z]*) *(.*)$/  ? ($1, $2, $3) :
                    /^([a-zA-Z0-9]+) +(.*)$/        ? ($1, 0, $2)  : ($_, 0, '');
                my $mandatory = $letter =~ /_/ ? 1 : 0;
                $letter =~ s/_//g;
                my $repeatable = $letter =~ /\+/ ? 1 : 0;
                $letter =~ s/\+//g;
                my @letter;
                push @letter, $letter, $mandatory, $repeatable, $table;
                push @letter, $regexp if $regexp;
                \@letter;
            } @parts ];
        }
        $rules{$tag_digit} = \@rule;

        @parts = ();
    }
    $self->rules( \%rules );

    my $code;
    if ( /^====/ ) {
        while (1) {
            if (/^==== *([A-Z]*)/) {
                ($code) = $1;
            }
            else {
                $self->table->{$code}->{$_} = 1;
            }
            while (<$fh>) {
                chop;
                last if $_;
            }
            last unless $_;
            s/^ *//;
            s/ *$//;
        }
    }
}


=method check( I<record> )

This method checks a biblio record, based on the current 'lint' object. The
biblio record is a L<MARC::Moose::Record> object. An array of validation
errors/warnings is returned. Those errors are just plain text explanation on
the reasons why the record doesn't comply with validation rules.

=cut
sub check {
    my ($self, $record) = @_;

    my @warnings;
    my $tag;        # Current tag
    my @fields;     # Array of fields;
    my $i_field;    # Indice in the current array of fields
    my $append = sub {
        my @text = ($tag);
        push @text, "($i_field)" if @fields > 1;
        push @text, ": ", shift;
        push @warnings, join('', @text);
    };
    my $fields_by_tag;
    for my $field ( @{$record->fields} ) {
        $fields_by_tag->{$field->tag} ||= [];
        push @{$fields_by_tag->{$field->tag}}, $field;
    }

    # Find out unknown fields
    my $rules = $self->rules;
    {
        my @unknown;
        for $tag ( keys %$fields_by_tag ) {
            push @unknown, $tag unless $rules->{$tag};
        }
        for (@unknown) {
            $tag = $_;
            $append->('Unknown tag');
        }
    }

    for my $rule ( values %$rules ) {
        # Test if a mandatory field is missing, and if a non-repeatable field
        # is repeated
        my ($mandatory, $repeatable);
        ($tag, $mandatory, $repeatable) = @$rule;
        my $fields = $fields_by_tag->{$tag};
        unless ($fields) {
            $append->("missing mandatory field") if $mandatory;
            next;
        }
        @fields = @$fields;
        $append->("non-repeatable field")  if !$repeatable && @fields > 1;

        $i_field = 1;

        # Control field
        if ( $tag lt '010' ) {
            my $regexp;
            (undef, undef, undef, $regexp) = @$rule;
            if ( $regexp ) {
                for my $field (@fields) {
                    $append->("invalid value, doesn't match /$regexp/")
                        if $field->value !~ /$regexp/; 
                    $i_field++;
                }
            }
            next;
        }

        # Standard field
        my ($ind, $subf);
        (undef, undef, undef, $ind, $subf) = @$rule;
        for my $field (@fields) {
            next if ref($field) ne 'MARC::Moose::Field::Std';
            for (my $i=1; $i <=2 ; $i++) {
                my $value = $i == 1 ? $field->ind1 : $field->ind2;
                my $regexp = $ind->[$i-1];
                $regexp =~ s/#/ /g;
                $regexp =~ s/,/|/g;
                $append->("invalid indicator $i '$value' , must be " . $ind->[$i-1])
                    if $value !~ /$regexp/;
            }
            # Search subfields which shouldn't be there
            my @forbidden;
            for (@{$field->subf}) {
                my ($letter, $value) = @$_;
                next unless $letter;
                next if grep { $_->[0] =~ $letter } @$subf;
                push @forbidden, $letter;
            }
            $append->("forbidden subfield(s): " . join(', ', @forbidden))
                if @forbidden;

            for (@$subf) {
                my ($letters, $mand, $repet, $table, $regexp) = @$_;
                for my $letter (split //, $letters) {
                    my @values = $field->subfield($letter);
                    $append->("\$$letter mandatory subfield is missing")
                        if @values == 0 && $mand;
                    $append->("\$$letter is repeated") if @values > 1 && !$repet;
                    my $i = 1;
                    my $multi = @values > 1;
                    for my $value (@values) {
                        if ( $table && ! $self->table->{$table}->{$value} ) {
                            $append->(
                                "subfield \$$letter" .
                                ($multi ? "($i)" : "") .
                                " contains '$value' not in $table table");
                        }
                        if ( $regexp && $value !~ /$regexp/ ) {
                            $append->(
                                "invalid subfield \$$letter" .
                                ($multi ? "($i)" : "") .
                                ", should be $regexp");
                        }
                        $i++;
                    }
                }
            }
            $i_field++;
        }
    }

    return @warnings;
}


__PACKAGE__->meta->make_immutable;

1;

=head1 SYNOPSYS

 use MARC::Moose::Record;
 use MARC::Moose::Reader::File::Iso2709;
 use MARC::Moose::Lint::Checker;

 # Read an ISO2709 file, and dump found errors
 my $reader = MARC::Moose::Reader::File::Iso2709->new(
     file => 'biblio.mrc' );
 my $lint = MARC::Moose::Lint::Checker->new(
     file => 'unimarc.rules' );
 while ( my $record = $reader->read() ) {
     if ( my @result = $lint->check($record) ) {
         say "Biblio record #", $record->field('001')->value;
         say join("\n", @result), "\n";
     }
 }

=head1 VALIDATION RULES

Validation rules are defined in a textual form. The file is composed of two
parts: (1) B<field rules>, (2) B<validation tables>.

(1) B<Field rules> define validation rules for each tag. A blank line separates
tags. For example:

 102+
 #
 #
 abc+i@CTRY ^[a-z]{3}$
 2+

Line 1 contains the field tag. If a + is present, the field is repeatable. If a
_ is present, the field is mandatory. For I<control fields> (tag under 010), an
optional second line can contain a regular expression on which validating field
content. For <standard fields>, line 2 and 3 contains a regular expression on
which indicators 1 and 2 are validated. # means a blank indicator. Line 4 and
the following define rules for validating subfields. A first part contains
subfield's letters, and + (repeatable) and/or _ (mandatory), followed by an
optional validation table name begining with @. A blank separates the first
part from the second part. The second part contains a regular expression on
which subfield content is validated.

(2) B<Validation tables> part of the file allow to define several validation
tables. The table name begins with C<==== TABLE NAME> in uppercase. Then each
line is a code in the validation table.

This is for example, a simplified standard UNIMARC validation rules file:

 005
 \d{14}\.\d

 100_
 #
 #
 a ^[0-9]{8}[a-ku][0-9 ]{8}[abcdeklu ]{3}[a-huyz][01 ][a-z]{3}[a-cy][01|02|03|04|05|06|07|08|09|10|11|50]{2}

 101_
 0|1|2
 #
 abcdfghij+@LANG ^[a-z]{3}$

 200_
 0|1
 #
 a_+
 bcdefghi+
 v
 z5+

 ==== CTRY
 AF
 AL
 DZ
 GG
 GN
 GW
 GY
 HT
 HM
 VE
 VN
 VG
 VI
 ZM
 ZW
 
 ==== LANG
 aar
 afh
 afr
 afa
 ain
 aka
 akk

=head1 SEE ALSO

=for :list
* L<MARC::Moose>
* L<MARC::Moose::Lint::Processor>

