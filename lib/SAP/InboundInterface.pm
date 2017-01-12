package SAP::InboundInterface;

use 5.010;
use strict;
use warnings;
use utf8;
use Text::Unidecode;

require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(
    initialize_invoice
    set_header
    add_invoice_line
    render_invoice
    normalize
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );
our @EXPORT = ();
our $VERSION = '0.01';

=pod

=head1 NAME

SAP::InboundInterface - SAP invoice data file generator

=head1 SYNOPSIS

    initialize_invoice();
    set_header({
        'SGTXT' => 'Header',
        'DOCDATE' => '20160208',
        'BASELINEDATE' => '20160214',
        'AMOUNT' => '12.98',
    });
    add_invoice_line({
        'AMOUNT' => '12.00',
        'SGTXT' => 'subtotal',
    });
    add_invoice_line({
        'AMOUNT' => '0.98',
        'SGTXT' => 'tax',
    });
    print render_invoice();

=head1 DESCRIPTION

SAP::InboundInterface is a module to simplify generation of SAP invoice data 
files.  It does not actually create the data files; that is the responsibility
of the caller.  Instead, it writes to C<STDOUT>.

=head2 Header columns

The following header columns are supported.  For length, alignment, and
default value, consult C<InboundInterface.pm>.

=over 4

=item TYPE

=item SGTXT

=item DOCDATE

=item BASELINEDATE

=item XBLNR

=item VENDORTYPE

=item LIFNR

=item AMOUNT

=item BUSCS

=item ZLSCH

=item UZAWE

=item ZLSPR

=item REGUL

=back

=cut

# For each column, specify the length, preferred alignment, and default value.
# Fill character is space.
my @header_format = (
    # Column        Len Align Default
    ['TYPE',          1, 'l', 'H'   ],
    ['SGTXT',        50, 'l', ''    ],
    ['DOCDATE',       8, 'l', ''    ],
    ['BASELINEDATE',  8, 'l', ''    ],
    ['XBLNR',        16, 'l', ''    ],
    ['VENDORTYPE',    4, 'l', 'ZOTV'],
    ['LIFNR',        10, 'l', ''    ],
    ['AMOUNT',       16, 'r', ''    ],
    ['BUSCS',         1, 'l', 'R'   ],
    ['ZLSCH',         1, 'l', ''    ],
    ['UZAWE',         2, 'l', ''    ],
    ['ZLSPR',         1, 'l', ''    ],
    ['REGUL',         1, 'l', ''    ],
);
my @header_columns = ();
my %header_format = ();
foreach my $header_format (@header_format) {
    my $column = shift @{$header_format};
    push @header_columns, $column;
    $header_format{$column} = $header_format;
}

=pod 

=head2 Invoice line columns

The following invoice line columns are supported.  For length, alignment, and
default value, consult C<InboundInterface.pm>.

=over 4

=item TYPE

=item SAKNR

=item KOSTL

=item AMOUNT

=item SHKZG

=item SGTXT

=back

=cut

my @detail_format = (
    # Column  Len Align Default
    ['TYPE',    1, 'l', 'D'],
    ['SAKNR',  10, 'l', '' ],
    ['KOSTL',  10, 'l', '' ],
    ['AMOUNT', 16, 'r', '' ],
    ['SHKZG',   1, 'l', 'S'],
    ['SGTXT',  50, 'l', '' ],
);
my @detail_columns = ();
my %detail_format = ();
foreach my $detail_format (@detail_format) {
    my $column = shift @{$detail_format};
    push @detail_columns, $column;
    $detail_format{$column} = $detail_format;
}

my %header = ();
my @details = ();

=pod

=head2 Methods

=over 4

=item C<initialize_invoice()>

Reset the header to the default, and clear any existing invoice lines.

=cut

sub initialize_invoice {
    %header = ();
    foreach my $column (@header_columns) {
        my $default = ${$header_format{$column}}[2];
        $header{$column} = $default;
    }
    @details = ();
}

=pod

=item C<set_header({'column' =E<gt> $value, ...})>

Set the given columns to the specified values.  Omitted columns are ignored.
Thus this method could be called several times with partial information if
desired, or once with a single hash reference.

=cut

sub set_header {
    my (
        $hash_ref,
    ) = @_;
    foreach my $column (keys %{$hash_ref}) {
        $header{$column} = ${$hash_ref}{$column};
    }
}

=pod

=item C<add_invoice_line({'column' =E<gt> $value, ...})>

Initialize a fresh invoice line with the default data, set the given columns
to the specified values, and append the result to the current invoice.

=cut

sub add_invoice_line {
    my (
        $hash_ref,
    ) = @_;

    # We shouldn't get called after render_invoice(), but if we are,
    # we need to make sure that there's only one invoice line marked with
    # TYPE 'L'.
    if (scalar(@details) > 0) {
        ${$details[$#details]}{'TYPE'} = 'D';
    }

    # Initialize a new detail line.
    my %detail = ();
    foreach my $column (@detail_columns) {
        my $default = ${$detail_format{$column}}[2];
        $detail{$column} = $default;
    }

    # Store the user-requested columns.
    foreach my $column (keys %{$hash_ref}) {
        $detail{$column} = ${$hash_ref}{$column};
    }

    # Add to the current invoice.
    push @details, \%detail;
}

=pod

=item C<render_invoice()>

Format the current invoice and print it to STDOUT.

=cut

sub render_invoice {
    # Ensure that final detail is labeled properly.
    ${$details[$#details]}{'TYPE'} = 'L';

    my @output = ();
    push @output, render(\%header, \%header_format, @header_columns);
    foreach my $detail_ref (@details) {
        push @output, render($detail_ref, \%detail_format, @detail_columns);
    }

    return join('', @output);
}

sub render {
    my (
        $hash_ref,
        $format_ref,
        @columns,
    ) = @_;

    my @pieces = ();
    foreach my $column (@columns) {
        my $normalized = normalize($format_ref, $column, ${$hash_ref}{$column});
        push @pieces, $normalized;
    }

    return join('', @pieces) . "\r\n";
}

sub normalize {
    my (
        $format_ref,
        $column,
        $value,
    ) = @_;

    $value = unidecode($value);

    if (exists ${$format_ref}{$column}) {
        my $format    = ${$format_ref}{$column};
        my $size      = ${$format}[0];
        my $alignment = ${$format}[1];

        if (length($value) > $size) {
            $value = substr($value, 0, $size);
        }

        if (length($value) < $size) {
            my $spacer = ' ' x ($size - length($value));
            if ('r' eq $alignment) {
                $value = $spacer . $value;
            }
            else {
                $value = $value . $spacer;
            }
        }

        return $value;
    }
    else {
        return 0;
    }
}

=pod

=back

=head1 COPYRIGHT

Copyright (C) 2016 Michael Slone <m.slone@gmail.com>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

=cut

1;
