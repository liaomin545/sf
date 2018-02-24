#!/usr/bin/perl
###############################################################
# rename encrypted files from B2

# inpit files
my $file_STATE = "data_20180207/EQP Status History.csv";
my $file_EPR = "data_20180207/EPR.csv";
my $file_TITO = "data_20180207/Product history.csv";
my $file_SETUP = "data_20180207/Recipe setup time.csv";
# "data/Lot priority weight.csv"       # no need to rename
my $RENAME_HOME = "tmp/";

my $PRINT_FULL = 0;		# print AREA, EQPTYPE, STAGE
my $SKIP_JOB_IN_OUT = 1;
use strict;

# mapping files
my %LOTID;	my $LOTID_idx = 0;
open (FOUT_LOTID, ">$RENAME_HOME/map_lotid.csv");
print FOUT_LOTID "LOTID (B2),LOTID (SmartFabs)\n";

my %EQPID;	my $EQPID_idx = 0;
open (FOUT_EQPID, ">$RENAME_HOME/map_eqpid.csv");
print FOUT_EQPID "EQPID (B2),EQPID (SmartFabs),EQPTYPE (SmartFabs)\n";

my %EQPID2TYPE;	# old EQPID -> old EQPTYPE

my %RECIPE;	my $RECIPE_idx = 0;
open (FOUT_RECIPE, ">$RENAME_HOME/map_recipe.csv");
print FOUT_RECIPE "RECIPE (B2),RECIPE (SmartFabs)\n";

my %EQPTYPE;	my $EQPTYPE_idx = 0;
if ($PRINT_FULL) {
	open (FOUT_EQPTYPE, ">$RENAME_HOME/map_eqptype.csv");
	print FOUT_EQPTYPE "EQPTYPE (B2),EQPTYPE (SmartFabs)\n";
}

my %STAGE;	my $STAGE_idx = 0;
if ($PRINT_FULL) {
	open (FOUT_STAGE, ">$RENAME_HOME/map_stage.csv");
	print FOUT_STAGE "STAGE (B2),STAGE (SmartFabs)\n";
}

my %AREA;	my $AREA_idx = 0;
if ($PRINT_FULL) {
	open (FOUT_AREA, ">$RENAME_HOME/map_area.csv");
	print FOUT_AREA "AREA (B2),AREA (SmartFabs)\n";
}
###############################################################
# "Product history.csv"
{

	# if LOTID,RECIPE appear more than once, rename LOTID to LOTID2, LOTID3, ...
	my %LOTID_RECIPE_cnt;	# {LOTID}{RECIPE} -> 1, 2, ...

	open (FIN, $file_TITO) or die "Can't open $file_TITO";
	open (FOUT, ">$RENAME_HOME/TITO1.csv");

	#AREA_ID,CLAIM_TIME,CUR_WAFER_QTY,EQP_ID,EQP_TYPE,LOT_ID,OPE_CATEGORY,PRIORITY_CLASS,RECIPE_ID
	
	my $header = <FIN>;	# skip header
	if (grep (/AREA_ID,CLAIM_TIME,CUR_WAFER_QTY,EQP_ID,EQP_TYPE,LOT_ID,OPE_CATEGORY,PRIORITY_CLASS,RECIPE_ID/,
		$header) == 0) {
		print "Error: TITO_file format wrong!\n";
		exit;
	}
	$header =~ s///g;
	print FOUT $header;

	while (my $line = <FIN>) {
		chomp ($line); $line =~ s///g;
		(my @fields) = split (",", $line);
		
		if ($SKIP_JOB_IN_OUT) {
			if (grep (/JOB/, $line)) {
				next;
			}
		}

		if (exists $LOTID_RECIPE_cnt{$fields[5]}{$fields[8]}) {
			if ($fields[6] eq "ARRIVE") {
				$LOTID_RECIPE_cnt{$fields[5]}{$fields[8]} ++;
			}
		} else {
			$LOTID_RECIPE_cnt{$fields[5]}{$fields[8]} = 1;
		}

		if ($PRINT_FULL) {
			if ((exists $AREA{$fields[0]}) == 0) {
				$AREA{$fields[0]} = $AREA_idx;
				printf FOUT_AREA "$fields[0],AREA%03d\n", $AREA_idx;
				$AREA_idx ++;
			}
		}

		if (length ($fields[1]) == 18) {
			$fields[1] = substr ($fields[1], 0, 15);
		}

		if ($PRINT_FULL) {
			if ((exists $EQPTYPE{$fields[4]}) == 0) {
				$EQPTYPE{$fields[4]} = $EQPTYPE_idx;
				printf FOUT_EQPTYPE "$fields[4],TYPE%03d\n", $EQPTYPE_idx;
				$EQPTYPE_idx ++;
			}
		}
		
		if ((exists $EQPID{$fields[3]}) == 0) {
			$EQPID{$fields[3]} = $EQPID_idx;
			printf FOUT_EQPID "$fields[3],E%03d\n", $EQPID_idx;
			$EQPID_idx ++;
		}
		
		if ((exists $LOTID{$fields[5]}) == 0) {
			$LOTID{$fields[5]} = $LOTID_idx;
			printf FOUT_LOTID "$fields[5],L%03d\n", $LOTID_idx;
			$LOTID_idx ++;
		}

		if ((exists $RECIPE{$fields[8]}) == 0) {
			$RECIPE{$fields[8]} = $RECIPE_idx;
			printf FOUT_RECIPE "$fields[8],R%03d\n", $RECIPE_idx;
			$RECIPE_idx ++;
		}

		if ($PRINT_FULL) {
			if (exists $EQPID2TYPE{$fields[3]}) {
				if ($EQPID2TYPE{$fields[3]} ne $fields[4]) {
					print "ERROR: EQPID=$fields[3] has two EQPTYPEs $EQPID2TYPE{$fields[3]} $fields[4]\n";
				}
			} else {
				$EQPID2TYPE{$fields[3]} = $fields[4];
			}
		}

		for (my $i = 0; $i < @fields; $i ++) {
			if ($i == 0) {
				if ($PRINT_FULL) {
					printf FOUT "AREA%03d,", $AREA{$fields[$i]};
				} else {
					print FOUT ",";
				}
			} elsif ($i == 1 && $fields[$i] eq "") {
				print FOUT "20180204 000000,";
			} elsif ($i == 3) {
				printf FOUT "E%03d,", $EQPID{$fields[$i]};
			} elsif ($i == 4) {
				if ($PRINT_FULL) {
					printf FOUT "TYPE%03d,", $EQPTYPE{$fields[$i]};
				} else {
					print FOUT ",";
				}
			} elsif ($i == 5) {
				printf FOUT "L%03d_%d,", $LOTID{$fields[$i]}, $LOTID_RECIPE_cnt{$fields[5]}{$fields[8]};
			} elsif ($i == 8) {
				printf FOUT "R%03d,", $RECIPE{$fields[$i]};
			} else {
				print FOUT "$fields[$i],";
			}
		}
		print FOUT "\n";
	}
	close FIN;
	close FOUT;
}
###############################################################
# "Recipe setup time.csv"
{
	open (FIN, $file_SETUP) or die "Can't open $file_SETUP";
	open (FOUT, ">$RENAME_HOME/SETUP1.csv") or die "Can't open SETUP1.csv";
	# EQP_TYPE,RECIPE_PREV,RECIPE_ID,TIME

	my $header = <FIN>;
	if (grep (/EQP_TYPE,RECIPE_PREV,RECIPE_ID,TIME/, $header) == 0) {
		print "Error: SETUP file format wrong!\n";
		exit;
	}
	$header =~ s///g;
	print FOUT $header;

	while (my $line = <FIN>) {
		chomp ($line); $line =~ s///g;
		(my @fields) = split (",", $line);

		if ($PRINT_FULL) {
			if ((exists $EQPTYPE{$fields[0]}) == 0) {
				$EQPTYPE{$fields[0]} = $EQPTYPE_idx;
				printf FOUT_EQPTYPE "$fields[0],TYPE%03d\n", $EQPTYPE_idx;
				$EQPTYPE_idx ++;
			}
		}

		if ((exists $RECIPE{$fields[1]}) == 0) {
			next;

			$RECIPE{$fields[1]} = $RECIPE_idx;
			printf FOUT_RECIPE "$fields[1],R%03d\n", $RECIPE_idx;
			$RECIPE_idx ++;
		}
		if ((exists $RECIPE{$fields[2]}) == 0) {
			next;

			$RECIPE{$fields[2]} = $RECIPE_idx;
			printf FOUT_RECIPE "$fields[2],R%03d\n", $RECIPE_idx;
			$RECIPE_idx ++;
		}
		for (my $i = 0; $i < @fields; $i ++) {
			if ($i == 0) { 
				if ($PRINT_FULL) {
					printf FOUT "TYPE%03d,", $EQPTYPE{$fields[$i]};
				} else {
					print FOUT ",";
				}
			} elsif ($i == 1 || $i == 2) { 
				printf FOUT "R%03d,", $RECIPE{$fields[$i]};
			} else {
 				print FOUT "$fields[$i],";
			}
		}
 		print FOUT "\n";
	}
	close FIN;
	close FOUT;
}
###############################################################
# EPR.csv
{
	open (FIN, $file_EPR) or die "Can't open $file_EPR";
	open (FOUT, ">$RENAME_HOME/EPR1.csv") or die "Can't open EPR1.csv";
	# EQP_TYPE,STAGE,RECIPE_ID,EQP_ID,CHAMLIST,UPDATE_TIME

	my $header = <FIN>;
	if (grep (/EQP_TYPE,STAGE,RECIPE_ID,EQP_ID,CHAMLIST,UPDATE_TIME/, $header) == 0) {
		print "Error: EPR file format wrong!\n";
		exit;
	}
	$header =~ s///g;
	print FOUT $header;

	while (my $line = <FIN>) {
		chomp ($line); $line =~ s///g;
		(my @fields) = split (",", $line);
	
		if ($PRINT_FULL) {
			if ((exists $EQPTYPE{$fields[0]}) == 0) {
				$EQPTYPE{$fields[0]} = $EQPTYPE_idx;
				printf FOUT_EQPTYPE "$fields[0],TYPE%03d\n", $EQPTYPE_idx;
				$EQPTYPE_idx ++;
			}

			if ((exists $STAGE{$fields[1]}) == 0) {
				$STAGE{$fields[1]} = $STAGE_idx;
				printf FOUT_STAGE "$fields[1],STAGE%03d\n", $STAGE_idx;
				$STAGE_idx ++;
			}
		}

		if ((exists $RECIPE{$fields[2]}) == 0) {
			next;

			$RECIPE{$fields[2]} = $RECIPE_idx;
			printf FOUT_RECIPE "$fields[2],R%03d\n", $RECIPE_idx;
			$RECIPE_idx ++;
		}
		if ((exists $EQPID{$fields[3]}) == 0) {
			next;

			$EQPID{$fields[3]} = $EQPID_idx;
			printf FOUT_EQPID "$fields[3],E%03d\n", $EQPID_idx;
			$EQPID_idx ++;
			print "WARNING: EQPID $fields[3] in EPR but not in TITO\n";
		}

		if ($PRINT_FULL) {
			if (exists $EQPID2TYPE{$fields[3]}) {
				if ($EQPID2TYPE{$fields[3]} ne $fields[0]) {
					print "ERROR! EQPID=$fields[3] has two EQPTYPEs $EQPID2TYPE{$fields[3]} $fields[0]\n";
					exit;
				}
			} else {
				$EQPID2TYPE{$fields[3]} = $fields[0];
			}
		}

		for (my $i = 0; $i < @fields; $i ++) {
			if ($i == 0) { 
				if ($PRINT_FULL) {
					printf FOUT "TYPE%03d,", $EQPTYPE{$fields[0]};
				} else {
					printf FOUT ",";
				}
			} elsif ($i == 1) { 
				if ($PRINT_FULL) {
					printf FOUT "STAGE%03d,", $STAGE{$fields[1]};
				} else {
					printf FOUT ",";
				}
			} elsif ($i == 2) { 
				printf FOUT "R%03d,", $RECIPE{$fields[2]};
			} elsif ($i == 3) { 
				printf FOUT "E%03d,", $EQPID{$fields[3]};
			} elsif ($i == 5) { 
				printf FOUT ",";
			} else {
 				print FOUT "$fields[$i],";
			}
		}
 		print FOUT "\n";

	}
	close FIN;
	close FOUT;
}
###############################################################
# "EQP Status History.csv"
{
	open (FIN, $file_STATE) or die "Can't open $file_STATE";
	open (FOUT, ">$RENAME_HOME/STATE1.csv") or die "Can't open STATE1.csv";
	# EQP_ID,TIME,STATE,PREVIOUSSTATE

	my $header = <FIN>;
	if (grep (/EQP_ID,TIME,STATE,PREVIOUSSTATE/, $header) == 0) {
		print "Error: STATE file format wrong!\n";
		exit;
	}
	$header =~ s///g;
	print FOUT $header;

	while (my $line = <FIN>) {
		chomp ($line); $line =~ s///g;
		(my @fields) = split (",", $line);
	
		if ((exists $EQPID{$fields[0]}) == 0) {
			next;

			$EQPID{$fields[0]} = $EQPID_idx;
			printf FOUT_EQPID "$fields[0],E%03d,\n", $EQPID_idx;
			$EQPID_idx ++;
			print "WARNING: EQPID $fields[0] does not appear in TITO\n";
		}

		if (length ($fields[1]) == 18) {
			$fields[1] = substr ($fields[1], 0, 15);
		}

		for (my $i = 0; $i < @fields; $i ++) {
			if ($i == 0) {
				printf FOUT "E%03d,", $EQPID{$fields[0]};
				next;
			}
			print FOUT "$fields[$i],";
		}
		print FOUT "\n";
	}
	close FIN;
	close FOUT;
}

close FOUT_LOTID;
close FOUT_EQPID;
close FOUT_RECIPE;
close FOUT_EQPTYPE;
close FOUT_STAGE;
close FOUT_AREA;
