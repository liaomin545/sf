#!/usr/bin/perl
###############################################################
# assume TITO1 is already in sorted order: LOTID, then TIME
#
# skip LOTID whose PROCESS_END is at 20170204 000000

use strict;
my $DIR = "tmp";
my $PRINT_PROCESS_END = 1;

my %ALREADY_END;	# {LOTID}{RECIPE} -> 1;
{
	open (FIN, "$DIR/TITO1.csv") or die "Can't open $DIR/TITO1.csv";
	#AREA_ID,CLAIM_TIME,CUR_WAFER_QTY,EQP_ID,EQP_TYPE,LOT_ID,OPE_CATEGORY,PRIORITY_CLASS,RECIPE_ID,LOT_TYPE

	while (my $line = <FIN>) {
		(my @fields) = split (",", $line);
		if (	($fields[1] eq "20180204 000000") &&
			($fields[6] eq "PROCESS_END")) {
			$ALREADY_END{$fields[5]}{$fields[8]} = 1;
			print "WARNING: SKIPPED DUE TO EARLY FINISH LOTID=$fields[5],RECIPE=$fields[8]\n";
		}
	}
	close FIN;
}

# skip any activity with 20180203
# skip any activity with 20180205
{
	open (FIN, "$DIR/TITO1.csv") or die "Can't open $DIR/TITO1.csv";
	open (FOUT, ">$DIR/TITO2.csv") or die "Can't open $DIR/TITO2.csv";
	#AREA_ID,CLAIM_TIME,CUR_WAFER_QTY,EQP_ID,EQP_TYPE,LOT_ID,OPE_CATEGORY,PRIORITY_CLASS,RECIPE_ID,LOT_TYPE

	my $header = <FIN>;
	print FOUT $header;

	while (my $line = <FIN>) {

		if ($PRINT_PROCESS_END == 0) {
			if (grep (/PROCESS_END/, $line)) {
				next;
			}
		}

		(my @fields) = split (",", $line);

		if (substr($fields[1], 0, 8) le "20180203") {
			print "WARNING: SKIPPED DUE TO EARLY $line";
			next;
		}

		if (substr($fields[1], 0, 8) ge "20180205") {
			print "WARNING: SKIPPED DUE TO LATE $line";
			next;
		}

		if ($ALREADY_END{$fields[5]}{$fields[8]} == 1) {
			next;
		}

		print FOUT "$line";
	}

	close FIN;
	close FOUT;
}
