#!/usr/bin/env perl -w
use strict;
use warnings;
use DateTime;
use Fcntl ':flock';
use File::Slurp;
use Getopt::Long;
use HTML::Entities;
use POSIX;
use XML::LibXML;
use XML::Validate;
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
my $report = 0;
# It would be nice to check against this.
#my $xsd = 'https://developers.exlibrisgroup.com/resources/xsd/invoice_payment.xsd';

GetOptions(
    'root=s'        => \$root,
    'destination=s' => \$destination,
    'log=s'         => \$log,
    'report=s'      => \$report)
    or die "$0: can't load options: $!";

if (!$root || !$destination) {
    if ($log) {
        debug("no configuration available, exiting");
    }
    die "$0: no configuration available, exiting";
}

my %error_types = (
    'xml'      => 'Alma XML parsing errors',
    'invoice'  => 'Invoice errors',
);
my %errors = ();
my $error_type;
foreach $error_type (keys %error_types) {
    $errors{$error_type} = ();
}
foreach $error_type (keys %error_types) {
    push @{$errors{$error_type}}, 'foo';
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
# Sample data file name:  d_aplibr_uklibraries20151015
my $data_file = strftime('d_aplibr_uklibraries%Y%m%d', localtime());
debug("Generating data file $data_file in $outbox");

# Process Alma XML
opendir ($dh, $todo)
    or die "$0: can't open directory $todo: $!";
open(my $data_fh, '>', "$outbox/$data_file")
    or die "$0: can't open file $outbox/$data_file for output: $!";
    binmode $data_fh, ":encoding(UTF-8)";
my $successes = 0;
foreach my $file (readdir $dh) {
    next if $file =~ /^\./;
    if ($file =~ /\.xml$/ and -f "$todo/$file") {
        my ($error, @entries) = export_invoices("$todo/$file");
        #record_error('xml', "test error for $file");
        if ($error) {
            debug("failed to generate output for $file");
            rename "$todo/$file", "$failure/$file";
        }
        else {
            print $data_fh join('', @entries);
            $successes++;
            rename "$todo/$file", "$success/$file";
        }
    }
}
close($data_fh) or die "$0: can't close file $outbox/$data_file: $!";

if ($successes > 0) {
    debug("Submitting $data_file to $destination");
    chmod 0664, "$outbox/$data_file";
    rename "$outbox/$data_file", "$destination/inbox/$data_file";
}
else {
    debug("No input files, deleting $data_file");
    unlink "$outbox/$data_file";
}

# File report
my $error_count = 0;
foreach $error_type (keys %error_types) {
    $error_count += scalar(@{$errors{$error_type}}) - 1;
}

if ($error_count > 0) {
    foreach $error_type (keys %error_types) {
        if (scalar(@{$errors{$error_type}}) > 1) {
            shift @{$errors{$error_type}};
            my $heading = $error_types{$error_type};
            # Newline is deliberate
            report("$heading\n");
            foreach my $message (@{$errors{$error_type}}) {
                report(" * $message");
            }
            report("\n");
        }
    }
}

sub export_invoices {
    my (
        $alma_file,
        $success,
        $failure,
    ) = @_;

    my @export = ();

    debug("processing $alma_file");
    my $validator = new XML::Validate(Type => 'LibXML');
    my $alma_contents = read_file($alma_file);
    my $doc = 0;
    if ($validator->validate($alma_contents)) {
        my $parser = XML::LibXML->new;
        $doc = $parser->parse_file($alma_file);
    }
    else {
        debug("can't parse $alma_file");
        record_error('xml', "Alma file $alma_file is not valid XML");
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
        else {
            $header{'LIFNR'} = '';
        }

        # Moreover, we are not permitted to transmit credit card transactions.
        # These are identified by '**CC**'.
        if ($header{'LIFNR'} =~ /\*\*CC\*\*/) {
            record_error('invoice', "$unique_identifier: no credit card transactions permitted");
            next INVOICE;
        }

        # Reverse POs are also not permitted.
        if ($header{'LIFNR'} =~ /reverse po/i) {
            record_error('invoice', "$unique_identifier: no reverse POs permitted");
            next INVOICE;
        }

        set_header(\%header);

        my @invoice_lines = $invoice->getElementsByTagName('invoice_line');
        my @valid_invoice_lines = ();
        my $pos = 0;

        INVOICE_LINE: foreach my $invoice_line (@invoice_lines) {
            my $line_amount = get_unique_field($invoice_line, 'total_price');
            my $reporting_code = get_unique_field($invoice_line, 'reporting_code');
            if ($line_amount =~ /^0*\.?0*$/ or $reporting_code eq 'NotFoundError') {
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
                day   => 18,
            );

            # Before 2016-07-18, cost center and G/L code are
            # stored in the external_id element (in that order),
            # delimited by a hyphen.  Afterward, G/L code is
            # stored in reporting_code, and cost center is stored
            # in external_id.
            #
            # Note: 2016-07-18 is *part of* the new epoch.
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

    if (scalar(@collection) > 0) {
        return $collection[0]->getFirstChild->getData;
    }
    else {
        return 'NotFoundError';
    }
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

sub report {
    my (
        $message,
    ) = @_;

    open(my $report_fh, '>>', $report)
        or die "$0: can't open $report for appending: $!";

    say $report_fh $message;
}

sub record_error {
    my (
        $type,
        $message,
    ) = @_;

    push @{$errors{$type}}, $message;
}
