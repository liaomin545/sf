#!/usr/bin/perl
###############################################################
# calculate score from TITO
use strict;

my $DIR = "tmp2";

my %ARRIVE;		# {LOTID}{RECIPE} -> time (sec)
my %PRIORITY;		# {LOTID}{RECIPE} -> int

my @weight;
	$weight[0] = 105;
	$weight[1] = 100;
	$weight[2] = 35;
	$weight[3] = 30;
	$weight[4] = 21;
	$weight[5] = 20;
	$weight[6] = 15;
	$weight[7] = 15;
	$weight[8] = 10;
my $score = 0;

sub seconds {
	return (substr ($_[0], 9, 2) * 3660 +
		substr ($_[0], 11, 2) * 60 +
		substr ($_[0], 13, 2));
}

{
	open (FIN, "$DIR/TITO2.csv") or die "Can't open $DIR/TITO2.csv";
	open (FOUT, ">$DIR/score.csv") or die "Can't open $DIR/score.csv";
	#AREA_ID,CLAIM_TIME,CUR_WAFER_QTY,EQP_ID,EQP_TYPE,LOT_ID,OPE_CATEGORY,PRIORITY_CLASS,RECIPE_ID

	print FOUT "LOTID,RECIPE,ARRIVE,PROCESS_START,PRIORITY,WAITING\n";

	print FOUT "processed lots\n";
	while (my $line = <FIN>) {

		chomp ($line);
		(my @fields) = split (",", $line);

		if ($fields[6] eq "ARRIVE") {
			if (	(exists $ARRIVE{$fields[5]}{$fields[8]})  &&
				($ARRIVE{$fields[5]}{$fields[8]} ne "")) {
				print "ERROR! ARRIVE TWICE: $line\n";
				exit;
			}
			$ARRIVE{$fields[5]}{$fields[8]} = $fields[1];
			$PRIORITY{$fields[5]}{$fields[8]} = $fields[7];
			next;
		}

		if ($fields[6] eq "PROCESS_START") {
			if (	((exists $ARRIVE{$fields[5]}{$fields[8]}) == 0) ||
				($ARRIVE{$fields[5]}{$fields[8]} eq "")) {
				print "WARNING! NO ARRIVE: $line ASSUME 20180204 000000\n";
				$ARRIVE{$fields[5]}{$fields[8]} = "20180204 000000";
				$PRIORITY{$fields[5]}{$fields[8]} = $fields[7];
			}

			if ($PRIORITY{$fields[5]}{$fields[8]} != $fields[7]) {
				print "WARNING: PRIORITY CHANGED\n";
			}

			my $wait = seconds ($fields[1]) - seconds ($ARRIVE{$fields[5]}{$fields[8]});
			print FOUT "$fields[5],"; 	# LOTID
			print FOUT "$fields[8],";	# RECIPE
			print FOUT "$ARRIVE{$fields[5]}{$fields[8]},";	# ARRIVE
			print FOUT "$fields[1],";	# PROCESS_START
			print FOUT "$fields[7],";	# PRIORITY
			print FOUT "$wait\n";	# WAITING

			$score += $wait * $weight[$fields[7]];
			$ARRIVE{$fields[5]}{$fields[8]} = "";
		}
	}
	close FIN;

	print FOUT "waiting lots\n";
	foreach my $L (keys %ARRIVE) {
	foreach my $R (keys %{$ARRIVE{$L}}) {
		if ((exists $ARRIVE{$L}{$R}) == 0) {
			next;
		}
		if ($ARRIVE{$L}{$R} eq "") {
			next;
		}

		my $wait = seconds ("20180204 235959") - seconds ($ARRIVE{$L}{$R});
		print FOUT "$L,";
		print FOUT "$R,";
		print FOUT "$ARRIVE{$L}{$R},";
		print FOUT "20180204 235959,";
		print FOUT "$PRIORITY{$L}{$R},";
		print FOUT "$wait\n";

		$score += $wait * $weight[$PRIORITY{$L}{$R}];
		$ARRIVE{$L}{$R} = "";
	}}
	print FOUT "score = $score\n";
}
