#!/usr/bin/env perl -w
use strict;
use warnings;
use DateTime;
use Fcntl ':flock';
use Getopt::Long;
use HTML::Entities;
use POSIX;
use XML::LibXML;
use SAP::InboundInterface ':all';
use feature 'say';

# The inbox and todo directory handling requires that
# only one copy of the reader is running at a time.
INIT {
    open *{0}
        or die "$0: failed: $!";
    flock *{0}, LOCK_EX|LOCK_NB
        or die "$0 is already running\n";
}

# Pick up configuration.
my $root = 0;
my $destination = 0;
my $log = 0;
# It would be nice to check against this.
#my $xsd = 'https://developers.exlibrisgroup.com/resources/xsd/invoice_payment.xsd';

GetOptions(
    'root=s'        => \$root,
    'destination=s' => \$destination,
    'log=s'         => \$log)
    or die "$0: can't load options: $!";

if (!$root || !$destination) {
    if ($log) {
        debug("no configuration available, exiting");
    }
    die "$0: no configuration available, exiting";
}

my $inbox   = "$root/inbox";
my $todo    = "$root/todo";
my $outbox  = "$root/outbox";
my $success = "$root/success";
my $failure = "$root/failure";

debug("queueing Alma XML files for processing");
my $dh;
opendir ($dh, $inbox)
    or die "$0: can't open directory $inbox: $!";
foreach my $file (readdir $dh) {
    next if $file =~ /^\./;
    if ($file =~ /\.xml$/ and -f "$inbox/$file") {
        rename "$inbox/$file", "$todo/$file";
    }
}

# Begin building data file
# Sample data file name:  d_aplibr_uklibraries_2015-10-15-210001
my $data_file = strftime('d_aplibr_uklibraries_%Y-%m-%d-%H%M%S', localtime());
debug("Generating data file $data_file in $outbox");

# Process Alma XML
opendir ($dh, $todo)
    or die "$0: can't open directory $todo: $!";
open(my $data_fh, '>', "$outbox/$data_file")
    or die "$0: can't open file $outbox/$data_file for output: $!";
foreach my $file (readdir $dh) {
    next if $file =~ /^\./;
    if ($file =~ /\.xml$/ and -f "$todo/$file") {
        my ($error, @entries) = export_invoices("$todo/$file");
        if ($error) {
            debug("failed to generate output for $file");
            rename "$todo/$file", "$failure/$file";
        }
        else {
            print $data_fh join('', @entries);
            rename "$todo/$file", "$success/$file";
        }
    }
}
close($data_fh) or die "$0: can't close file $outbox/$data_file: $!";

debug("Submitting $data_file to $destination");
rename "$outbox/$data_file", "$destination/inbox/$data_file";

sub export_invoices {
    my (
        $alma_file,
        $success,
        $failure,
    ) = @_;

    my @export = ();

    debug("processing $alma_file");
    my $parser = XML::LibXML->new;
    my $doc = $parser->parse_file($alma_file);
    if (!$doc) {
        debug("can't parse $alma_file");
        return 1, @export;
    }
    my $root = $doc->documentElement;

    INVOICE: foreach my $invoice ($root->getElementsByTagName('invoice')) {
        initialize_invoice();
        my %header = (
            'VENDORTYPE' => '    ',
        );

        # We only need to process invoices with a nonzero amount.
        my @amounts = $invoice->getElementsByTagName('invoice_amount');
        my $amount = get_unique_field($amounts[0], 'sum');
        if ($amount =~ /^0*\.?0*$/) {
            next INVOICE;
        }
        else {
            $header{'AMOUNT'} = $amount;
        }

        my $unique_identifier = get_unique_field($invoice, 'unique_identifier');
        $header{'SGTXT'} = join(' ', $unique_identifier, 'Univ of Kentucky Libraries');
        $header{'DOCDATE'} = strftime('%Y%m%d', localtime());

        # Each invoice must contain exactly one invoice_date.
        # The sample XML file provided by Ex Libris formats the
        # invoice date in UK format (DDMMYYYY) instead of the
        # ISO 8601 format required by SAP.
        #
        # It looks like the production export is going to use
        # non-standard American dates (MM/DD/YYYY), so I'll check
        # for that first, and fall back to a generic attempt to
        # guess the format afterward.
        my $raw_invoice_date = get_unique_field($invoice, 'invoice_date');
        if ($raw_invoice_date =~ /^(?<month>\d\d)\/(?<day>\d\d)\/(?<year>\d\d\d\d)$/) {
            $header{'BASELINEDATE'} = join('', $+{year}, $+{month}, $+{day});
        }
        else {
            $header{'BASELINEDATE'} = convert_to_iso8601($raw_invoice_date);
        }

        $header{'XBLNR'} = get_unique_field($invoice, 'invoice_number');

        # The vendor_FinancialSys_Code is optional, and the sample
        # file from Ex Libris does not include it.
        #
        # However, we require it locally.
        my @codes = $invoice->getElementsByTagName('vendor_FinancialSys_Code');
        if (scalar(@codes) > 0) {
            $header{'LIFNR'} = $codes[0]->getFirstChild->getData;
        }

        set_header(\%header);

        my @invoice_lines = $invoice->getElementsByTagName('invoice_line');
        my @valid_invoice_lines = ();
        my $pos = 0;

        INVOICE_LINE: foreach my $invoice_line (@invoice_lines) {
            my $line_amount = get_unique_field($invoice_line, 'total_price');
            if ($line_amount =~ /^0*\.?0*$/) {
                next INVOICE_LINE;
            }
            else {
                push @valid_invoice_lines, $invoice_line;
            }
        }

        foreach my $invoice_line (@valid_invoice_lines) {
            $pos++;
            my %details = (
                'AMOUNT' => get_unique_field($invoice_line, 'total_price'),
            );

            my $now = DateTime->now;
            my $cost_center_epoch = DateTime->new(
                year  => 2016,
                month => 7,
                day   => 1,
            );

            # Before 2016-07-01, cost center and G/L code are
            # stored in the external_id element (in that order),
            # delimited by a hyphen.  Afterward, G/L code is
            # stored in reporting_code, and cost center is stored
            # in external_id.
            #
            # Here I am assuming that 2016-07-01 is *part of* the
            # cost center epoch, that is, that *on* 2016-07-01, the
            # new behavior will be in place.
            #
            # I'm also explicitly assuming that the invoice line includes
            # exactly one external_id element.  The XSD does not require
            # this.
            if ($now < $cost_center_epoch) {
                my $external_id = get_unique_field($invoice_line, 'external_id');
                if ($external_id =~ /(?<cost_center>[^-]+)-(?<glcode>[^-]+)$/) {
                    $details{'SAKNR'} = $+{glcode};
                    $details{'KOSTL'} = $+{cost_center};
                }
            }
            else {
                $details{'SAKNR'} = get_unique_field($invoice_line, 'reporting_code');
                $details{'KOSTL'} = get_unique_field($invoice_line, 'external_id');
            }

            # The po_line_info element is optional according to the spec.
            my @po_line_infos = $invoice_line->getElementsByTagName('po_line_info');
            if (scalar(@po_line_infos) > 0) {
                my @sgtxt_pieces = ();
                my $po_line_info = $po_line_infos[0];
                my $line_number = substr(get_unique_field($po_line_info, 'po_line_number'), 0, 10);
                # The mms_record_id element is optional, and the Ex Libris example
                # does not use it.
                my @mms_record_ids = $po_line_info->getElementsByTagName('mms_record_id');
                my $bib_id = '          ';
                if (scalar(@mms_record_ids) > 0) {
                    $bib_id = get_unique_field($po_line_info, 'mms_record_id');
                }
                $bib_id = substr($bib_id, 0, 10);

                my @titles = $po_line_info->getElementsByTagName('po_line_title');
                my $title = ' "';
                if (scalar(@titles) > 0) {
                    $title = decode_entities($titles[0]->getFirstChild->getData);
                }

                $details{'SGTXT'} = "$line_number $bib_id $title";
            }

            add_invoice_line(\%details);
        }

        push @export, render_invoice();
    }

    return 0, @export;
}

sub get_unique_field
{
    my (
        $xml,
        $xpath,
    ) = @_;

    my @collection = $xml->getElementsByTagName($xpath);
    return $collection[0]->getFirstChild->getData;
}

sub convert_to_iso8601
{
    my (
        $date,
    ) = @_;

    if ($date =~ /^(?<century>\d\d)(?<decade>\d\d)(?<month>\d\d)(?<day>\d\d)$/) {
        my $century = $+{century};
        my $decade  = $+{decade};
        my $month   = $+{month};
        my $day     = $+{day};

        if (($month == 19 or $month == 20) and (0 <= $day and $day <= 99)) {
            if ((1 <= $century and $century <= 31) and (1 <= $decade and $decade <= 12)) {
                # Probably UK format.
                ($century, $decade, $month, $day) = ($month, $day, $decade, $century);
            }
            elsif ((1 <= $century and $century <= 12) and (1 <= $decade and $decade <= 31)) {
                # Probably US format.
                ($century, $decade, $month, $day) = ($month, $day, $century, $decade);
            }
        }

        return join('', $century, $decade, $month, $day);
    }
    else {
        return '18790314';
    }
}

sub uk_to_iso8601
{
    my (
        $uk_date,
    ) = @_;

    if ($uk_date =~ /^(\d\d)(\d\d)(\d\d\d\d)$/) {
        my $day   = $1;
        my $month = $2;
        my $year  = $3;
        return join('', $year, $month, $day);
    }
    else {
        return '18790314';
    }
}

sub debug {
    my (
        $message,
    ) = @_;

    open(my $log_fh, '>>', $log)
        or die "$0: can't open $log for appending: $!";

    my $datestring = strftime('[%Y-%m-%d %H:%M:%S %z]:', localtime());

    my @log_pieces = (
        'Reader',
        $datestring,
        $message,
    );

    say $log_fh join(' ', @log_pieces);
}
