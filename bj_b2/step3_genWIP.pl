#!/usr/bin/perl
use strict;
########################################################
# generate WIP for scheduler
my $PK_DATE	= "20171224";
my $PK_START	= $PK_DATE . " 000000";
my $PK_END	= $PK_DATE . " 235959";

my $DIR		= "tmp";
my $TITO_FILE	= "$DIR/TITO2.csv";	# renamed and reordered
my $WIP_FILE	= "$DIR/WIP1.csv";
########################################################
# Running WIP are lots START at PK_START -> no running WIP
# Coming WIP are lots START after PK_START
{	
	open (FIN, $TITO_FILE) or die "Can't open $TITO_FILE";
	# AREA_ID,CLAIM_TIME,CUR_WAFER_QTY,EQP_ID,EQP_TYPE,LOT_ID,OPE_CATEGORY,PRIORITY_CLASS,RECIPE_ID,LOT_TYPE
	# ,20180204 000000,2,E000,,L000_1,ARRIVE,2,R000,M,
	# ,20180204 092139,2,E000,,L000_1,PROCESS_START,2,R000,M,
	# ,20180204 092923,2,E000,,L000_1,PROCESS_END,2,R000,M,

	open (FOUT, ">$WIP_FILE") or die "Can't open $WIP_FILE";
	print FOUT "LOTID,RECIPE,ARRIVE,FLAG,WAFER,PRI\n";

	while (my $line = <FIN>) {
		chomp ($line); $line =~ s/\"//g; $line =~ s///g;
		(my @fields) = split (",", $line);

		if ($fields[6] ne "ARRIVE") {
			next;
		}

		print FOUT "$fields[5],";
		print FOUT "$fields[8],";
		print FOUT "$fields[1],";

		if ($fields[1] eq "20180204 000000") {
			print FOUT "0,";
		} else {
			printf FOUT "%d,", 1 + substr ($fields[1], 9, 2);
		}
		print FOUT "$fields[2],";
		print FOUT "$fields[7]\n";
	}
	close FIN;
	close FOUT;
}

#######################################################
#
## initial waiting WIP are also reported as incomine WIP with time PK_START
########################################################
## initial WIP: lots arrive before PK_START
##		and PROCESS_END not before PK_START
## running WIP: JOBIN before START_TIME
## waiting WIP: JOBIN after START_TIME
#my %IWIP_ARRIVE;	# {$LOTID}{$RECIPE}
#my %IWIP_WAFER;		# {$LOTID}{$RECIPE}
#my %IWIP_EQPID;		# {$LOTID}{$RECIPE}
#my %IWIP_PRI;		# {$LOTID}{$RECIPE}
#my %IWIP_JOBIN;		# {$LOTID}{$RECIPE}
#my %IWIP_PROCESS_END;	# {$LOTID}{$RECIPE}, need for EQPID available
#
#sub read_IWIP {
#	open (FIN, $TITO_FILE) or die "Can't open $TITO_FILE";
#	# AREA_ID,CLAIM_TIME,CUR_WAFER_QTY,EQP_ID,EQP_TYPE,LOT_ID,OPE_CATEGORY,PRIORITY_CLASS,RECIPE_ID,LOT_TYPE
#	# ,20180204 000000,2,E000,,L000_1,ARRIVE,2,R000,M,
#	# ,20180204 092139,2,E000,,L000_1,PROCESS_START,2,R000,M,
#	# ,20180204 092923,2,E000,,L000_1,PROCESS_END,2,R000,M,
#
#	while (my $line = <FIN>) {
#		chomp ($line); $line =~ s/\"//g; $line =~ s///g;
#		(my @fields) = split (",", $line);
#		my $TIME = $fields[1];
#		my $WAFER = $fields[2];
#		my $EQPID = $fields[3];
#		my $LOTID = $fields[5];
#		my $OPE = $fields[6];
#		my $PRI = $fields[7];
#		my $RECIPE = $fields[8];
#
#		if ($IWIP_ARRIVE{$LOTID}{$RECIPE} eq "SKIP") {	# already see PROCESS_END
#			next;
#		}
#
#		if (($OPE eq "ARRIVE") && ($TIME lt $PK_START)) {	# potential WIP
#			$IWIP_ARRIVE{$LOTID}{$RECIPE} = $TIME;
#			$IWIP_WAFER{$LOTID}{$RECIPE} = $WAFER;
#			$IWIP_EQPID{$LOTID}{$RECIPE} = $EQPID;
#			$IWIP_PRI{$LOTID}{$RECIPE} = $PRI;
#			$IWIP_JOBIN{$LOTID}{$RECIPE} = "";
#			$IWIP_PROCESS_END{$LOTID}{$RECIPE} = "";
#			next;
#		}
#
#		if (($OPE eq "JOBIN") && ($TIME lt $PK_START)) {
#			$IWIP_JOBIN{$LOTID}{$RECIPE} = $TIME;
#			next;
#		}
#
#		if (($OPE eq "PROCESS_END") && ($IWIP_JOBIN{$LOTID}{$RECIPE} ne "")) { 
#			if ($TIME lt $PK_START) {
#				$IWIP_ARRIVE{$LOTID}{$RECIPE} = "SKIP";
#			} else {
#				if ($IWIP_PROCESS_END{$LOTID}{$RECIPE} eq "") {
#					$IWIP_PROCESS_END{$LOTID}{$RECIPE}= $TIME;
#					# earliest PROCESS_END!
#				}
#			}
#			next;
#		}
#	}
#	close FIN;
#
#	# copy waiting WIP into incoming WIP and set FLAG=0
#	foreach my $L (keys %IWIP_ARRIVE) {
#	foreach my $R (keys %{$IWIP_ARRIVE{$L}}) {
#		if ($IWIP_ARRIVE{$L}{$R} eq "SKIP") {
#			next;
#		}
#		if ($IWIP_JOBIN{$L}{$R} eq "") {
#			$CWIP_ARRIVE{$L}{$R} = $IWIP_ARRIVE{$L}{$R};
#			$CWIP_FLAG{$L}{$R} = 0;
#			$CWIP_WAFER{$L}{$R} = $IWIP_WAFER{$L}{$R};
#			$CWIP_PRI{$L}{$R} = $IWIP_PRI{$L}{$R};
#		}
#	}}
#}
#
#sub print_IWIP {
#
#	print "ARRIVE,LOTID,RECIPE,WAFER,EQPID,PRI,JOBIN,PROCESS_END\n";
#
#	foreach my $LOTID (keys %IWIP_ARRIVE) {
#	foreach my $RECIPE (keys %{$IWIP_ARRIVE{$LOTID}}) {
#		if ($IWIP_ARRIVE{$LOTID}{$RECIPE} eq "SKIP") {
#			next;
#		}
#		print "$IWIP_ARRIVE{$LOTID}{$RECIPE},";
#		print "$LOTID,";
#		print "$RECIPE,";
#		print "$IWIP_WAFER{$LOTID}{$RECIPE},";
#		print "$IWIP_EQPID{$LOTID}{$RECIPE},";
#		print "$IWIP_PRI{$LOTID}{$RECIPE},";
#		print "$IWIP_JOBIN{$LOTID}{$RECIPE},";
#		print "$IWIP_PROCESS_END{$LOTID}{$RECIPE}\n";
#
#	}}
#}
#########################################################
#my %READY;	# EQPID start time
#
#sub gen_READY {
#	foreach my $LOTID (keys %IWIP_ARRIVE) {
#	foreach my $RECIPE (keys %{$IWIP_ARRIVE{$LOTID}}) {
#		if ($IWIP_ARRIVE{$LOTID}{$RECIPE} eq "SKIP") {	# not WIP
#			next;
#		}
#		if ($IWIP_JOBIN{$LOTID}{$RECIPE} eq "") {	# waiting WIP
#			next;
#		}
#		if (exists $READY{$IWIP_EQPID{$LOTID}{$RECIPE}}) {
#			if ($READY{$IWIP_EQPID{$LOTID}{$RECIPE}} < $IWIP_PROCESS_END{$LOTID}{$RECIPE}) {
#				$READY{$IWIP_EQPID{$LOTID}{$RECIPE}} = $IWIP_PROCESS_END{$LOTID}{$RECIPE};
#			}
#		} else {
#			$READY{$IWIP_EQPID{$LOTID}{$RECIPE}} = $IWIP_PROCESS_END{$LOTID}{$RECIPE};
#		}
#	}}
#
#
#	open (FOUT, ">$READY_FILE") or die "Can't open $READY_FILE";
#	print FOUT "EQIPD,READY\n";
#	foreach my $EQPID (keys %READY) {
#		print FOUT "$EQPID,$READY{$EQPID}\n";
#	}
#	close FOUT;
#}
#########################################################
## output format
## LOTID,EQPID,PILOT,FLAG,RECIPE,WAFER
## DFK011.04,APDCI01,NO,1,8141VIA4-PHOTO,1
#sub print_INPUT4 {
#
#	open (FOUT, ">$OUTPUT_FILE") or die "Can't open $OUTPUT_FILE";
#
#	print FOUT "LOTID,EQPID,RECIPE,FLAG,ARRIVE,WAFER,PITCH\n";
#
#	foreach my $LOTID (keys %CWIP_ARRIVE) {
#	foreach my $RECIPE (keys %{$CWIP_ARRIVE{$LOTID}}) {
#		#foreach my $EQPID (keys %PITCH) {
#		#	if ((exists $PITCH{$EQPID}{$RECIPE}) == 0) {
#		#		next;
#		#	}
#			print FOUT "$LOTID,";
#			#print FOUT "$EQPID,";
#			print FOUT "$RECIPE,";
#			print FOUT "$CWIP_FLAG{$LOTID}{$RECIPE},";
#			print FOUT "$CWIP_ARRIVE{$LOTID}{$RECIPE},";
#			print FOUT "$CWIP_WAFER{$LOTID}{$RECIPE},";
#		#	print FOUT "$PITCH{$EQPID}{$RECIPE},";
#			print FOUT "\n";
#		#}
#	}}
#	close FOUT;
#}
#
#read_CWIP;
#read_IWIP;
#print_CWIP;
#gen_READY;
##print_INPUT4;
