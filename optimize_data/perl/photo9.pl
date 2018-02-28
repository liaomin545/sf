#!/usr/bin/perl
use strict;
########################################################
#my $INPUT_FILE= "../Data/ILI.csv";
my $INPUT_FILE= "../data/DUV.csv";
my $LP_FILE = "LP.lp";
#my $LP_SOLVE = "~/Dropbox/LP/lp_solve_5.5.2.0/lp_solve";
my $LP_SOLVE = "lp_solve";
my $LP_SOLUTION_FILE = "LP_solution.txt";
########################################################
my $DEBUG_FILE = "debug.txt";
my $DEBUG = 1;			# 0/1: to print debug info
if ($DEBUG) {
	open (FDEBUG, ">", $DEBUG_FILE) or die "Can't open $DEBUG_FILE";
}
########################################################
my $GOAL = "MIN_WEIGHT";
# WEIGHT = (lot_low penalty) + (lot_high penalty) + (pilot_high penalty)
# where lot_low and lot_high are compare to AVE_LOT_ACC
#	pilot_high is only for the current flag
# TODO: weights needs to be optimized

# lot low penalty, where X is the number of lots
my $PENALTY_LOT_LT_2 = 1;	# max {0, (AVE-2)-X} * $PENALTY_LOT_LT_2
my $PENALTY_LOT_LT_3 = 2;	# max {0, (AVE-3)-X} * $PENALTY_LOT_LT_3
my $PENALTY_LOT_LT_4 = 4;	# max {0, (AVE-4)-X} * $PENALTY_LOT_LT_4
my $PENALTY_LOT_LT_5 = 8;	# max {0, (AVE-5)-X} * $PENALTY_LOT_LT_5

# lot high penalty, where X is the number of lots
my $PENALTY_LOT_GT_2 = 1;	# max {0, X-(AVE+2)} * $PENALTY_LOT_GT_2
my $PENALTY_LOT_GT_3 = 2;	# max {0, X-(AVE+3)} * $PENALTY_LOT_GT_3
my $PENALTY_LOT_GT_4 = 8;	# max {0, X-(AVE+4)} * $PENALTY_LOT_GT_4
my $PENALTY_LOT_GT_5 = 16;	# max {0, X-(AVE+5)} * $PENALTY_LOT_GT_5

# pilot high penalty function, where Y is the number of pilots
my $PENALTY_PILOT_GT_3 = 1;	# max {0, Y-3} * $PENALTY_PILOT_GT_3
my $PENALTY_PILOT_GT_4 = 4;	# max {0, Y-4} * $PENALTY_PILOT_GT_4
########################################################
my $FLAG_MAX = 6;	# TODO: change FLAG_MAX to variable, now fixed at 6
my %LOTID_FLAG_def;	# (LOTID,FLAG) -> RECIPE
my %EQPID_def;		# EQPID -> 1
my @EQPID_list;		# sorted array of EQPID, fixed order for print only
my %RECIPE_def;		# RECIPE -> 1
	$RECIPE_def{"IDLE"} = 1;
my @RECIPE_list;	# sorted array of RECIPE, fixed order for print only
my %RECIPE_FLAG_lot;	# (RECIPE,FLAG) -> number of lots for this RECIPE & FLAG
my %USABLE;		# (EQPID, RECIPE, FLAG) -> YES/NO/blank, NO can be changed to YES at later FLAGs
my %ASSIGN;		# (EQPID, RECIPE, FLAG) -> lots from LP solution
my %PRE_ASSIGN;		# (EQPID, RECIPE, FLAG) -> lots
########################################################
# convert wafers to lot, resolution at 1/8
# treat each wafer as 1/25 lot will cause fractional solutions
# other options at 1/4 or 1/16
sub wafer2lot {
	if ($_[0] >= 23) { return 1.000; }
	if ($_[0] >= 20) { return 0.875; }
	if ($_[0] >= 17) { return 0.750; }
	if ($_[0] >= 14) { return 0.625; }
	if ($_[0] >= 11) { return 0.500; }
	if ($_[0] >=  8) { return 0.375; }
	if ($_[0] >=  5) { return 0.250; }
	if ($_[0] >=  1) { return 0.125; }
	return 0;
}
########################################################
# compute average lot for each flag
my @AVE_LOT;		# FLAG -> average lots per EQPID for this flag
my @AVE_LOT_ACC;	# FLAG -> average lots per EQPID accumulative from flag 1 
sub compute_AVE_LOT {
	my $eqpid_cnt = int (@EQPID_list);

	my @lot_cnt;
	for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
		$lot_cnt[$F] = 0;
	}

	foreach my $R (keys %RECIPE_FLAG_lot) {
	foreach my $F (keys %{$RECIPE_FLAG_lot{$R}}) {
		if (exists $RECIPE_FLAG_lot{$R}{$F}) {
			$lot_cnt[$F] += $RECIPE_FLAG_lot{$R}{$F};
		}
	}}

	$AVE_LOT_ACC[0] = 0;

	for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
		$AVE_LOT[$F] = $lot_cnt[$F] / $eqpid_cnt;
		$AVE_LOT_ACC[$F] = $AVE_LOT_ACC[$F-1] + $AVE_LOT[$F];

		if ($DEBUG) {
			printf FDEBUG "F=$F,AVE_LOT=%.3f,AVE_LOT_ACC=%.3f\n", $AVE_LOT[$F],$AVE_LOT_ACC[$F];
		}
	}
}
########################################################
sub read_INPUT {
	open (FIN, $INPUT_FILE) or die "Can't open $INPUT_FILE";
	my $header = <FIN>;	# skip header

	# LOTID,ECSEQ,PAS STATUS,COMING FLAG,RETICLE,QTY
	# DFP780.01,BPILI33,NO,1,8824ZERO-PHOTO,1

	while (my $line = <FIN>) {
		chomp ($line); $line =~ s/\"//g; $line =~ s///g;
		(my @fields) = split (",", $line);

		# check if any field is empty
		my $check_empty = 0;
		foreach my $f (@fields) {
			if ($f eq "") {
				$check_empty = 1;
				last;
			}
		}
		if ($check_empty == 1) {
			if ($DEBUG) {
				print FDEBUG "WARNING: FILED EMPTY $line\n";
			}
			next;
		}

		# assume "_" does not appear in input, TODO: confirm with S1
		# "_" is used as special symbol for LP
		if (grep (/_/, $line)) {
			print "ERROR! INPUT FILE CONTAINS _\n";
			exit;
		}

		my $LOTID = $fields[0];
		my $EQPID = $fields[1];
		my $FLAG = $fields[3];
		my $RECIPE = $fields[4];
		if (grep (/^X/, $RECIPE)) {	# skip X lots
			if ($DEBUG) {
				print FDEBUG "WARNING: SKIP X LOT $line\n";
			}
			next;
		}
		$RECIPE =~ s/-/~/g;	# replace "-" by "~" for LP solver


		$EQPID_def{$EQPID} = 1;
		$RECIPE_def{$RECIPE} = 1;

		if (exists $USABLE{$EQPID}{$RECIPE}{$FLAG}) {
			if ($USABLE{$EQPID}{$RECIPE}{$FLAG} ne $fields[2]) {
				if ($DEBUG) {
					print FDEBUG "WARNING: $EQPID $RECIPE $FLAG ";
					print FDEBUG "usable definition inconsistent, treat as YES\n";
				}
				$USABLE{$EQPID}{$RECIPE}{$FLAG} = "YES";	# inconsistent PILOT treat as YES
			}
		} else {
			$USABLE{$EQPID}{$RECIPE}{$FLAG} = $fields[2];
		}

		# a LOTID may appear in two or more flags
		# in each flag, all appearances of a LOTID are the same lot, TODO: confirm with S1
		if (exists $LOTID_FLAG_def{$LOTID}{$FLAG}) {
			if ($LOTID_FLAG_def{$LOTID}{$FLAG} ne $RECIPE) {
				print "ERROR! LOTID appears twice in one FLAG $line\n";
				exit;
			}
			next;
		}

		$LOTID_FLAG_def{$LOTID}{$FLAG} = $RECIPE;

		if (exists $RECIPE_FLAG_lot{$RECIPE}{$FLAG}) {
			$RECIPE_FLAG_lot{$RECIPE}{$FLAG} += wafer2lot ($fields[5]);
		} else {
			$RECIPE_FLAG_lot{$RECIPE}{$FLAG} = wafer2lot ($fields[5]);
		}
	}
	close FIN;

	@EQPID_list = sort (keys %EQPID_def);
	@RECIPE_list = sort (keys %RECIPE_def);

	# check if a USABLE changes from YES to NO
	foreach my $EQPID (keys %USABLE) {
	foreach my $RECIPE (keys %{$USABLE{$EQPID}}) {
		my $FLAG;
		for ($FLAG = 1; $FLAG < $FLAG_MAX; $FLAG ++) {
			if (exists $USABLE{$EQPID}{$RECIPE}{$FLAG}) {
				last;
			}
		}

		for (my $F = 1; $F < $FLAG_MAX; $F ++) {
			if ($DEBUG && exists $USABLE{$EQPID}{$RECIPE}{$F} &&
				($USABLE{$EQPID}{$RECIPE}{$F} ne $USABLE{$EQPID}{$RECIPE}{$FLAG})) {
				print FDEBUG "WARNING: usable for $EQPID $RECIPE is ";
				print FDEBUG "$USABLE{$EQPID}{$RECIPE}{$FLAG} at FLAG $FLAG but ";
				print FDEBUG "$USABLE{$EQPID}{$RECIPE}{$F} at FLAG $F, treat as ";
				print FDEBUG "$USABLE{$EQPID}{$RECIPE}{$FLAG}\n";
			}	
			$USABLE{$EQPID}{$RECIPE}{$F} = $USABLE{$EQPID}{$RECIPE}{$FLAG};
		}
	}}

	compute_AVE_LOT;
}
########################################################
sub print_USABLE {
# print initial usable matrix at FLAG=1
# rows are RECIPE, columns are an EQPID, entries are YES/NO/empty

	open (FOUT, ">usable.csv") or die "Can't open usable.csv";

	# print header line
	print FOUT "RECIPE,";
	foreach my $E (@EQPID_list) {
		print FOUT "$E,";
	}
	print FOUT "\n";

	foreach my $R (@RECIPE_list) {
		if ($R eq "IDLE") {
			next;
		}

		print FOUT "$R,";
		foreach my $E (@EQPID_list) {
			print FOUT "$USABLE{$E}{$R}{1},";
		}
		print FOUT "\n";
	}
	close FOUT;
}
########################################################
sub print_SOLUTION_MATRIX {
# rows are EQPID
# first 6 columns are lots for each flag, the 7th column is total lots
# next 6 columns are pilot lots for each flag, the 14th column is total pilot lots
# each entry is (number of lots)+(number of idle lots)

	open (FOUT, ">solution_matrix.csv") or die "Can't open solution_matrix.csv";

	print FOUT "EQPID,";
	for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
		print FOUT "lot($F),";
	}
	print FOUT "total_lot,";
	for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
		print FOUT "pilot($F),";
	}
	print FOUT "total_pilot\n";

	foreach my $E (@EQPID_list) {
		print FOUT "$E,";

		my $total_lot = 0;
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			my $flag_lot = 0;
			my $flag_idle = 0;

			foreach my $R (@RECIPE_list) {
				if ($ASSIGN{$E}{$R}{$F} > 0) {
					if ($R eq "IDLE") {
						$flag_idle += $ASSIGN{$E}{$R}{$F};
					} else {
						$flag_lot += $ASSIGN{$E}{$R}{$F};
					}
				}
			}
			#printf FOUT "%.3f+%.3f,", $flag_lot, $flag_idle;
			printf FOUT "%.3f,", $flag_lot;
			$total_lot += $flag_lot;
		}
		printf FOUT "%.3f,", $total_lot;

		my $total_pilot = 0;
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			my $flag_pilot = 0;
			foreach my $R (@RECIPE_list) {
				if ($ASSIGN{$E}{$R}{$F} > 0) {
					if ($USABLE{$E}{$R}{$F} eq "NO") {
						#$flag_pilot ++;
						$flag_pilot += $ASSIGN{$E}{$R}{$F} / $RECIPE_FLAG_lot{$R}{$F};
					}
				}
			}
			printf FOUT "%d,", $flag_pilot;
			$total_pilot += $flag_pilot;
		}
		printf FOUT "%d\n", $total_pilot;
	}
	close FOUT;
}
########################################################
sub print_SOLUTION_EQPID_RECIPE {

	open (FOUT, ">solution_eqpid_recipe.csv") or die "Can't open solution_eqpid_recipe.csv";

	print FOUT "EQPID,RECIPE,FLAG,LOT,PILOT\n";

	foreach my $E (@EQPID_list) {
		my $total_lot = 0;
		my $total_pilot = 0;

		foreach my $R (@RECIPE_list) {
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			if ((exists $ASSIGN{$E}{$R}{$F}) == 0) {
				next;
			}
			if ($ASSIGN{$E}{$R}{$F} == 0) {
				next;
			}
			$total_lot += $ASSIGN{$E}{$R}{$F};
			print FOUT "$E,$R,$F,$ASSIGN{$E}{$R}{$F}";
			if ($USABLE{$E}{$R}{$F} eq "NO") {
				print FOUT ",pilot";
				$total_pilot ++;
			}
			else {
				print FOUT ",";
			}
			print FOUT "\n";
		}}
		print FOUT "$E,,,$total_lot,$total_pilot\n\n";
	}

	close FOUT;
}
########################################################
sub print_SOLUTION_RECIPE_EQPID {

	open (FOUT, ">solution_recipe_eqpid.csv") or die "Can't open solution_recipe_eqpid.csv";

	print FOUT "RECIPE,FLAG,EQPID,LOT,PILOT\n";

	foreach my $R (@RECIPE_list) {
	for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
		my $non_empty = 0;

		foreach my $E (@EQPID_list) {
			if ((exists $ASSIGN{$E}{$R}{$F}) == 0) {
				next;
			}
			if ($ASSIGN{$E}{$R}{$F} == 0) {
				next;
			}

			$non_empty = 1;
			print FOUT "$R,$F,$E,$ASSIGN{$E}{$R}{$F},";
			if ($USABLE{$E}{$R}{$F} eq "NO") {
				print FOUT "pilot";
			}
			print FOUT "\n";
		}
		if ($non_empty == 1) {
			print FOUT "\n";
		}
	}}

	close FOUT;
}
#######################################################
# generate LP input file from FLAG=1 to current FLAG=$_[0]
sub gen_LP {
	my $FLAG_ITER = $_[0];

	open (FLP, ">", $LP_FILE) or die "Can't open $LP_FILE";

	# objective function
	print FLP "min: WEIGHT;\n";

	# Xijk pre-assigned
	foreach my $E (keys %PRE_ASSIGN) {
	foreach my $R (keys %{$PRE_ASSIGN{$E}}) {
	foreach my $F (keys %{$PRE_ASSIGN{$E}{$R}}) {
		if (exists $PRE_ASSIGN{$E}{$R}{$F}) {
			print FLP "X_$E";
			print FLP "_$R";
			print FLP "_$F";
			print FLP " = $PRE_ASSIGN{$E}{$R}{$F};\n";
		}
	}}}

	# Xijk >= 0, where i=EQIPID, j=RECIPE, k=FLAG
	foreach my $E (keys %EQPID_def) {
	foreach my $R (keys %RECIPE_def) {
		my $F = $FLAG_ITER;

		if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
			next;
		}
		if ((exists $USABLE{$E}{$R}{$F}) == 0) {
			next;
		}

		print FLP "X_$E";
		print FLP "_$R";
		print FLP "_$F >= 0;\n";
	}}

	# for each RECIPE, all lots must be processed
	foreach my $R (keys %RECIPE_def) {
		my $F = $FLAG_ITER;
		if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
			next;
		}

		my $first_time = 1;
		foreach my $E (keys %EQPID_def) {

			if ((exists $USABLE{$E}{$R}{$F}) == 0) {
				next;
			}

			if ($first_time == 0) {
				print FLP " + ";
			} else {
				$first_time = 0;
			}
			print FLP "X_$E";
			print FLP "_$R";
			print FLP "_$F";
		}
		if ($first_time == 0) {
			print FLP " = $RECIPE_FLAG_lot{$R}{$F};\n";
		}
	}

	# for current FLAG, penalty for pilot for each EQPID
	foreach my $E (keys %EQPID_def) {
		my $F = $FLAG_ITER;
		my $first_time = 1;
		foreach my $R (keys %RECIPE_def) {

			if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
				next;
			}
			if ((exists $USABLE{$E}{$R}{$F}) == 0) {
				next;
			}
			if ($USABLE{$E}{$R}{$F} eq "YES") {
				next;
			}

			if ($first_time == 0) {
				print FLP " + ";
			} else {
				$first_time = 0;
			}
			printf FLP "%.4f ", 1.0 / $RECIPE_FLAG_lot{$R}{$F};
			print FLP "X_$E";
			print FLP "_$R";
			print FLP "_$F";
		}

		print FLP " - PILOT_$E = 0;\n";

		# pilot3 = max {0, pilot-3}
		print FLP "PILOT3_$E >= 0;\n";
		print FLP "PILOT3_$E - PILOT_$E >= - 3;\n";
		# pilot4 = max {0, pilot-4}
		print FLP "PILOT4_$E >= 0;\n";
		print FLP "PILOT4_$E - PILOT_$E >= - 4;\n";
	}

	# for each EQPID, compute total lot
	foreach my $E (keys %EQPID_def) {
		my $first_time = 1;
		foreach my $R (keys %RECIPE_def) {
		for (my $F = 1; $F <= $FLAG_ITER; $F ++) {

			if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
				next;
			}
			if ((exists $USABLE{$E}{$R}{$F}) == 0) {
				next;
			}

			if ($first_time == 0) {
				print FLP " + ";
			} else {
				$first_time = 0;
			}
			print FLP "X_$E";
			print FLP "_$R";
			print FLP "_$F";
		}}

		if ($first_time == 1) {
			printf FDEBUG "WARNING: EQPID $E has no recipe to work\n";
			next;
		}

		print FLP " - T_$E = 0;\n";

		# LT2 = max {0, (AVE-2)-LOT}
		print FLP "LT2_$E >= 0;\n";
		printf FLP "LT2_$E + T_$E >= %d;\n", $AVE_LOT_ACC[$FLAG_ITER] - 2;

		# LT3 = max {0, (AVE-3)-LOT}
		print FLP "LT3_$E >= 0;\n";
		printf FLP "LT3_$E + T_$E >= %d;\n", $AVE_LOT_ACC[$FLAG_ITER] - 3;

		# LT4 = max {0, (AVE-4)-LOT}
		print FLP "LT4_$E >= 0;\n";
		printf FLP "LT4_$E + T_$E >= %d;\n", $AVE_LOT_ACC[$FLAG_ITER] - 4;

		# LT5 = max {0, (AVE-5)-LOT}
		print FLP "LT5_$E >= 0;\n";
		printf FLP "LT5_$E + T_$E >= %d;\n", $AVE_LOT_ACC[$FLAG_ITER] - 5;

		# GT2 = max {0, LOT-(AVE+2)}
		print FLP "GT2_$E >= 0;\n";
		printf FLP "GT2_$E - T_$E >= %d;\n", - ($AVE_LOT_ACC[$FLAG_ITER] + 2);

		# GT3 = max {0, LOT-(AVE+3)}
		print FLP "GT3_$E >= 0;\n";
		printf FLP "GT3_$E - T_$E >= %d;\n", - ($AVE_LOT_ACC[$FLAG_ITER] + 3);

		# GT4 = max {0, LOT-(AVE+4)}
		print FLP "GT4_$E >= 0;\n";
		printf FLP "GT4_$E - T_$E >= %d;\n", - ($AVE_LOT_ACC[$FLAG_ITER] + 4);

		# GT5 = max {0, LOT-(AVE+5)}
		print FLP "GT5_$E >= 0;\n";
		printf FLP "GT5_$E - T_$E >= %d;\n", - ($AVE_LOT_ACC[$FLAG_ITER] + 5);

	}

	# objective function
	print FLP "- WEIGHT";
	foreach my $E (keys %EQPID_def) {
		print FLP " + $PENALTY_PILOT_GT_4 PILOT4_$E";
		print FLP " + $PENALTY_PILOT_GT_3 PILOT3_$E";
		print FLP " + $PENALTY_LOT_LT_2 LT2_$E";
		print FLP " + $PENALTY_LOT_LT_3 LT3_$E";
		print FLP " + $PENALTY_LOT_LT_4 LT4_$E";
		print FLP " + $PENALTY_LOT_LT_5 LT5_$E";
		print FLP " + $PENALTY_LOT_GT_2 GT2_$E";
		print FLP " + $PENALTY_LOT_GT_3 GT3_$E";
		print FLP " + $PENALTY_LOT_GT_4 GT4_$E";
		print FLP " + $PENALTY_LOT_GT_5 GT5_$E";
	}
	print FLP " = 0;\n";

	close FLP;
}
	
########################################################
# read LP solution
sub read_LP {
	open (FIN, $LP_SOLUTION_FILE) or die "Can't open $LP_SOLUTION_FILE";

	while (my $line = <FIN>) {

		chomp ($line); $line =~ s/\"//g; $line =~ s///g;

		if (grep (/This problem is infeasible/, $line)) {
			print "$line\n";
			return 0;
		}

		if (grep (/WEIGHT/, $line)) {
		# WEIGHT                     29.875
			$line =~ s/  */,/;
			print FDEBUG "$line\n";
			next;
		}

		if (grep (/^X_/, $line)) {
		# X_APDI708_5959AAPHOTO_1            0
			$line =~ s/  */,/;
			$line =~ s/^X_//;
			$line =~ s/_/,/g;
			(my $E, my $R, my $F, my $LOT) = split (",", $line);
			$ASSIGN{$E}{$R}{$F} = $LOT;
			if ($DEBUG) {
				print FDEBUG "$line\n";
			}
		}
	}
	close FIN;
}
#############################################################
sub write_PRE_ASSIGN {
	my $F = $_[0];

	foreach my $E (keys %ASSIGN) {
	foreach my $R (keys %{$ASSIGN{$E}}) {
		if (exists $PRE_ASSIGN{$E}{$R}{$F}) {
			next;
		}
		if (exists $ASSIGN{$E}{$R}{$F}) {
			my $a = 0.125 * int ($ASSIGN{$E}{$R}{$F} * 8) ;
			$PRE_ASSIGN{$E}{$R}{$F} = $a;
			if ($DEBUG) {
				print FDEBUG "PRE_ASSIGN $E $R $F = $a, originally $ASSIGN{$E}{$R}{$F}\n";
			}
		}
	}}
}
#########################################################
sub write_ASSIGN_IDLE {
	my $FLAG_ITER = $_[0];

	foreach my $E (keys %EQPID_def) {
		# compute number of lots assigned at this flag
		my $lots = 0;
		for (my $F = 1; $F <= $FLAG_ITER; $F ++) {
			foreach my $R (keys %RECIPE_def) {
				if (exists $ASSIGN{$E}{$R}{$F}) {
					$lots += $ASSIGN{$E}{$R}{$F};
				}
			}
		}

		my $half = $AVE_LOT_ACC[$FLAG_ITER-1] + $AVE_LOT[$FLAG_ITER] / 2;
		my $idle = $half - $lots;
		if ($idle < 0) {
			next;
		}

		$ASSIGN{$E}{"IDLE"}{$FLAG_ITER} = int ($idle);
		$PRE_ASSIGN{$E}{"IDLE"}{$FLAG_ITER} = int ($idle);

		if ($DEBUG) {
			print FDEBUG "PRE_ASSIGN $E IDLE $FLAG_ITER = $idle , ave = $AVE_LOT_ACC[$FLAG_ITER], lot = $lots\n";
		}
	}
}
#########################################################
sub update_USABLE {
	my $F = $_[0];

	foreach my $E (keys %ASSIGN) {
	foreach my $R (keys %{$ASSIGN{$E}}) {
		if ($R eq "IDLE") {
			next;
		}
		if (exists $ASSIGN{$E}{$R}{$F}) {
			if ($USABLE{$E}{$R}{$F} eq "NO") {
				$USABLE{$E}{$E}{$F} = "YES";
				if ($DEBUG) {
					print FDEBUG "PILOT updated $E $R $F = YES\n";
				}
			}
		}
	}}
}
#########################################################
sub merge_largest_recipe {	# return 0: nothing to merge, 1: merged
	my $FLAG_ITER = $_[0];

	# step 1, find the largest split recipe
	my $R_largest;		# largest split recipe
	my $L_largest = 0;	# number of lots of largest split recipe
	my @E_list;		# list of EQPIDs for the largest split recipe

	foreach my $R (keys %RECIPE_def) {
		if ($R eq "IDLE") {
			next;
		}
		my $e_cnt = 0;
		my @E_tmp;
		foreach my $E (keys %EQPID_def) {
			if (exists $ASSIGN{$E}{$R}{$FLAG_ITER} == 0) {
				next;
			}
			if ($ASSIGN{$E}{$R}{$FLAG_ITER} == 0) {
				next;
			}
			$e_cnt ++;
			push @E_tmp, $E;
		}

		if ($e_cnt < 2) {	# if recipe is not split, skip
			next;
		}

		if ($DEBUG) {
			print FDEBUG "split recipe $R,$RECIPE_FLAG_lot{$R}{$FLAG_ITER}\n";
		}

		if ($RECIPE_FLAG_lot{$R}{$FLAG_ITER} > $L_largest) {
			$R_largest = $R;
			$L_largest = $RECIPE_FLAG_lot{$R}{$FLAG_ITER};
			@E_list = @E_tmp;
		}
	}

	if ($L_largest == 0) {
		return 0;
	}

	if ($DEBUG) {
		print FDEBUG "largest recipe = $R_largest, number of lots = $L_largest\n";
	}

	#  step 2, sort EQPIDs according to lots already assigned, excluding current one
	my @E_load;	# number of lots already assigned
	my @E_pilot;	# number of pilots required for FLAG_ITER
	for (my $i = 0; $i < @E_list; $i ++) {
		my $E = $E_list[$i];
		my $lots = 0;
		my $pilots = 0;

		foreach my $R (keys %{$ASSIGN{$E}}) {
		foreach my $F (keys %{$ASSIGN{$E}{$R}}) {

			if (($R eq $R_largest) && ($F == $FLAG_ITER)) {
				next;	# excluding current one
			}
			if (exists $ASSIGN{$E}{$R}{$F} == 0) {
				next;
			}
			if ($ASSIGN{$E}{$R}{$F} == 0) {
				next;
			}
			print FDEBUG "E=$E,R=$R,$ASSIGN{$E}{$R}{$F}\n";
			$lots += $ASSIGN{$E}{$R}{$F};

			if ($F == $FLAG_ITER && $USABLE{$E}{$R}{$F} eq "NO") {
				$pilots += $ASSIGN{$E}{$R}{$F} / $RECIPE_FLAG_lot{$R}{$F};
			}
		}}

		push @E_load, $lots;
		push @E_pilot, $pilots;
	}

	my @idx = sort { $E_load[$a] <=> $E_load[$b] } 0 .. $#E_load;
	@E_list = @E_list[@idx];
	@E_load = @E_load[@idx];

	my $first_yes = 0;	# index of first EQPID which does not need PILOT
	for (my $i = 0; $i < @idx; $i ++) {
		if ($USABLE{$E_list[$i]}{$R_largest}{$FLAG_ITER} eq "YES") {
			$first_yes = $i;
			last;
		}
	}

	for (my $i = 0; $i < @idx; $i ++) {
		print FDEBUG "E_list = $E_list[$i],E_load = $E_load[$i],E_pilot = $E_pilot[$i]\n";
	}

	# step 3, choose the first EQPID with min load #and not pilot
	$ASSIGN{$E_list[0]}{$R_largest}{$FLAG_ITER} = $RECIPE_FLAG_lot{$R_largest}{$FLAG_ITER};
	$PRE_ASSIGN{$E_list[0]}{$R_largest}{$FLAG_ITER} = $RECIPE_FLAG_lot{$R_largest}{$FLAG_ITER};
	for (my $i = 1; $i < @idx; $i ++) {
		$ASSIGN{$E_list[$i]}{$R_largest}{$FLAG_ITER} = 0;
		$PRE_ASSIGN{$E_list[$i]}{$R_largest}{$FLAG_ITER} = 0;
	}
	if ($DEBUG) {
		print FDEBUG "$R_largest $FLAG_ITER merged to $E_list[0]\n";
	}

	return 1;
}
##############################################################
#main
{
	read_INPUT;
	print_USABLE;
	#update_LOAD (0);

	for (my $FLAG_ITER = 1; $FLAG_ITER <= $FLAG_MAX; $FLAG_ITER ++) {
		undef %ASSIGN;
		gen_LP ($FLAG_ITER);
		system ("$LP_SOLVE $LP_FILE > $LP_SOLUTION_FILE");
		if (read_LP == 0) {
			exit;
		}

		write_PRE_ASSIGN ($FLAG_ITER);
		write_ASSIGN_IDLE ($FLAG_ITER);
		update_USABLE ($FLAG_ITER);

		while (merge_largest_recipe ($FLAG_ITER)) {
			;
		}
	}
	print_SOLUTION_MATRIX;
	print_SOLUTION_RECIPE_EQPID;
	print_SOLUTION_EQPID_RECIPE;
}
#########################################################
