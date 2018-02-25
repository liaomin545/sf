#!/usr/bin/perl
use strict;
# to do: change FLAG_MAX to variable
########################################################
#my $INPUT_FILE= "../Data/ILI_debug.csv";
my $INPUT_FILE= "../Data/DUV.csv";
my $LP_FILE = "LP.lp";
my $LP_SOLVE = "~/Dropbox/LP/lp_solve_5.5.2.0/lp_solve";
my $SOLUTION_FILE = "solution.txt";
########################################################
my $DEBUG_FILE = "debug.txt";
my $DEBUG = 1;			# 0/1: to print debug info
if ($DEBUG) {
	open (FDEBUG, ">", $DEBUG_FILE) or die "Can't open $DEBUG_FILE";
}
########################################################
my $GOAL = "MIN_WEIGHT";
# WEIGHT = (lot_low penalty) + (lot_high penalty) + (pilot_high penalty)
# where lot_low and lot_hight are compare to AVE_LOT_ACC
#	pilot_high is only for the current flag

# lot low prnalty, where X is the number of lots
my $PENALTY_LOT_LT_2 = 1;	# max {0, (AVE-2)-X} * $PENALTY_LOT_LT_2
my $PENALTY_LOT_LT_3 = 2;	# max {0, (AVE-3)-X} * $PENALTY_LOT_LT_3
my $PENALTY_LOT_LT_4 = 4;	# max {0, (AVE-4)-X} * $PENALTY_LOT_LT_4
my $PENALTY_LOT_LT_5 = 8;	# max {0, (AVE-5)-X} * $PENALTY_LOT_LT_5

# lot high prnalty, where X is the number of lots
my $PENALTY_LOT_GT_2 = 1;	# max {0, X-(AVE+2)} * $PENALTY_LOT_GT_2
my $PENALTY_LOT_GT_3 = 2;	# max {0, X-(AVE+3)} * $PENALTY_LOT_GT_3
my $PENALTY_LOT_GT_4 = 4;	# max {0, X-(AVE+4)} * $PENALTY_LOT_GT_4
my $PENALTY_LOT_GT_5 = 8;	# max {0, X-(AVE+5)} * $PENALTY_LOT_GT_5

# pilot high penalty function, where Y is the number of pilots
my $PENALTY_PILOT_GT_3 = 1;	# max {0, Y-3} * $PENALTY_PILOT_GT_3
my $PENALTY_PILOT_GT_4 = 4;	# max {0, Y-4} * $PENALTY_PILOT_GT_4

my $BUFFER_SIZE = 3;	# if an EQPID does not have enough lots,
			# fill IDLE until AVE - BUFFER_SIZE
########################################################
my $FLAG_MAX = 6;
my %LOTID_def;		# LOTID -> 1
my %EQPID_def;		# EQPID -> 1
my @EQPID_list;		# sorted array
my %RECIPE_def;		# RECIPE -> 1
	$RECIPE_def{"IDLE"} = 1;
my @RECIPE_list;	# sorted array
my %RECIPE_FLAG_lot;	# (RECIPE,FLAG) -> number of lots for this RECIPE & FLAG
my %USABLE;		# (EQPID, RECIPE) -> YES/NO/blank
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
my @AVE_LOT;		# FLAG -> ave lot per EQPID for this flag
my @AVE_LOT_ACC;	# FLAG -> ave lot per EQPID accumulate from flag 1 
sub ave_lot_per_flag {
	my $e_cnt = int (@EQPID_list);

	my @l_cnt;
	for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
		$l_cnt[$F] = 0;
	}

	foreach my $R (keys %RECIPE_FLAG_lot) {
	foreach my $F (keys %{$RECIPE_FLAG_lot{$R}}) {
		if (exists $RECIPE_FLAG_lot{$R}{$F}) {
			$l_cnt[$F] += $RECIPE_FLAG_lot{$R}{$F};
		}
	}}

	$AVE_LOT_ACC[0] = 0;

	for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
		$AVE_LOT[$F] = $l_cnt[$F] / $e_cnt;
		$AVE_LOT_ACC[$F] = $AVE_LOT_ACC[$F-1] + $AVE_LOT[$F];

		if ($DEBUG) {
			print FDEBUG "F=$F,AVE_LOT=$AVE_LOT[$F],AVE_LOT_ACC=$AVE_LOT_ACC[$F]\n";
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

		# _ is used as special symbol for LP
		if (grep (/_/, $line)) {
			print "ERROR! INPUT FILE CONTAINS _\n";
			exit;
		}

		my $LOTID = $fields[0];
		my $EQPID = $fields[1];
		my $PAS = $fields[2];
		my $FLAG = $fields[3];
		my $RECIPE = $fields[4];
		if (grep (/^X/, $RECIPE)) {	# skip X lots
			if ($DEBUG) {
				print FDEBUG "WARNING: SKIP X LOT $line\n";
			}
			next;
		}
		$RECIPE =~ s/-/__/g;	# replace - for LP solver

		my $lot = wafer2lot ($fields[5]);

		$EQPID_def{$EQPID} = 1;
		$RECIPE_def{$RECIPE} = 1;

		if (exists $USABLE{$EQPID}{$RECIPE}) {
			if ($USABLE{$EQPID}{$RECIPE} ne $PAS) {
				if ($DEBUG) {
					print FDEBUG "WARNING: $EQPID $RECIPE pilot inconsistent, treat as YES\n";
				}
				$USABLE{$EQPID}{$RECIPE} = "YES";	# inconsistent PILOT treat as YES
			}
		} else {
			$USABLE{$EQPID}{$RECIPE} = $PAS;
		}

		# assumption: each LOTID can only appear once
		if (exists $LOTID_def{$LOTID}) {
			next;
		}
		$LOTID_def{$LOTID} = 1;

		if (exists $RECIPE_FLAG_lot{$RECIPE}{$FLAG}) {
			$RECIPE_FLAG_lot{$RECIPE}{$FLAG} += $lot;
		} else {
			$RECIPE_FLAG_lot{$RECIPE}{$FLAG} = $lot;
		}
	}
	close FIN;

	@EQPID_list = sort (keys %EQPID_def);
	@RECIPE_list = sort (keys %RECIPE_def);

	ave_lot_per_flag;
}
########################################################
# print number of lots and usable matrix
sub print_USABLE {

	open (FOUT, ">usable.csv") or die "Can't open usable.csv";

	print FOUT "RECIPE,";
	for (my $F = 1; $F <= $FLAG_MAX ; $F ++) {
		print FOUT "$F,";
	}

	foreach my $E (@EQPID_list) {
		print FOUT "$E,";
	}
	print FOUT "\n";

	foreach my $R (@RECIPE_list) {
		print FOUT "$R,";
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			if (exists $RECIPE_FLAG_lot{$R}{$F}) {
				print FOUT "$RECIPE_FLAG_lot{$R}{$F},";
			} else {
				print FOUT "0,";
			}
		}

		foreach my $E (@EQPID_list) {
			print FOUT "$USABLE{$E}{$R},";
		}
		print FOUT "\n";
	}
	close FOUT;
}
########################################################
sub print_SOLUTION_MATRIX {

	open (FOUT, ">assign.csv") or die "Can't open assign.csv";

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
		my $total_idle = 0;
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
			if ($flag_idle == 0) {
				printf FOUT "%.3f,", $flag_lot;
			} else {
				printf FOUT "%.3f+%.3f,", $flag_lot, $flag_idle;
			}
			$total_lot += $flag_lot;
		}
		printf FOUT "%.3f,", $total_lot;

		my $total_pilot = 0;
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			my $flag_pilot = 0;
			foreach my $R (@RECIPE_list) {
				if ($ASSIGN{$E}{$R}{$F} > 0) {
					if ($USABLE{$E}{$R} eq "NO") {
						$flag_pilot ++;
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

	open (FOUT, ">eqpid_recipe.csv") or die "Can't open assign.csv";

	print FOUT "EQPID,RECIPE,FLAG,LOT,PILOT\n";

	foreach my $E (@EQPID_list) {
		my $total_lot = 0;
		my $total_pilot = 0;

		print FOUT "----------\n";
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
			if ($USABLE{$E}{$R} eq "NO") {
				print FOUT ",pilot";
				$total_pilot ++;
			}
			else {
				print FOUT ",";
			}
			print FOUT "\n";
		}}
		print FOUT "EQPID=$E,total_lot=$total_lot, total_pilot=$total_pilot\n";
	}

	close FOUT;
}
########################################################
sub print_SOLUTION_RECIPE_EQPID {

	open (FOUT, ">recipe_eqpid.csv") or die "Can't open assign.csv";

	foreach my $R (@RECIPE_list) {

		print FOUT "RECIPE=$R\n";
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
		foreach my $E (@EQPID_list) {
			if ((exists $ASSIGN{$E}{$R}{$F}) == 0) {
				next;
			}
			if ($ASSIGN{$E}{$R}{$F} == 0) {
				next;
			}
			print FOUT "\tEQPID=$E,FLAG=$F,LOT=$ASSIGN{$E}{$R}{$F},";
			if ($USABLE{$E}{$R} eq "NO") {
				print FOUT "pilot";
			}
			print FOUT "\n";
		}}
	}

	close FOUT;
}
#######################################################
# generate LP input file from FLAG=1 to current FLAG=$_[0]
sub gen_LP {
	my $FLAG_ITER = $_[0];

	open (FLP, ">", $LP_FILE) or die "Can't open $LP_FILE";

	# objective function
	print FLP "min: WEIGHT;\n";

	#printf FLP "MINTIME >= %d;\n", $AVE_LOT[$FLAG_ITER]-1.5;
	#print FLP "MINTIME >= $MIN_TIME_LIMIT;\n";
	#print FLP "MAXTIME <= $MAX_TIME_LIMIT;\n";
	#print FLP "PILOTLIMITEQPIDFLAG <= $PILOT_LIMIT_EQPID_FLAG;\n";

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
	for (my $F = 1; $F <= $FLAG_ITER; $F ++) {

		if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
			next;
		}
		if ((exists $USABLE{$E}{$R}) == 0) {
			next;
		}

		print FLP "X_$E";
		print FLP "_$R";
		print FLP "_$F >= 0;\n";
	}}}

	# for each RECIPE, all lots must be processed
	foreach my $R (keys %RECIPE_def) {
	for (my $F = 1; $F <= $FLAG_ITER; $F ++) {
		my $first_time = 1;
		foreach my $E (keys %EQPID_def) {

			if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
				next;
			}
			if ((exists $USABLE{$E}{$R}) == 0) {
				next;
			}

			if ($first_time == 0) {
				print FLP " + ";
			}
			$first_time = 0;
			print FLP "X_$E";
			print FLP "_$R";
			print FLP "_$F";
		}
		if ($first_time == 0) {
			print FLP " = $RECIPE_FLAG_lot{$R}{$F};\n";
		}
	}}

	# for each FLAG, pilot runs <= $PILOT_LIMIT_FLAG
	#for (my $F = 1; $F <= $FLAG_ITER; $F ++) {
#	{
#		my $F = $FLAG_ITER;
#
#		my $first_time = 1;
#
#		foreach my $E (keys %EQPID_def) {
#		foreach my $R (keys %RECIPE_def) {
#
#			if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
#				next;
#			}
#			if (exists $USABLE{$E}{$R} == 0) {
#				next;
#			}
#
#			if ($USABLE{$E}{$R} eq "YES") {
#				next;
#			}
#
#			if ($first_time == 0) {
#				print FLP " + ";
#			}
#			$first_time = 0;
#			printf FLP "%.4f ", 1.0 / $RECIPE_FLAG_lot{$R}{$F};
#			print FLP "X_$E";
#			print FLP "_$R";
#			print FLP "_$F";
#		}}
#
#		if ($first_time == 0) {
#			print FLP " <= $PILOT_LIMIT_FLAG;\n";
#		}
#	}

	# for each EQPID and current FLAG, compute total pilot
	foreach my $E (keys %EQPID_def) {
	#for (my $F = 1; $F <= $FLAG_ITER; $F ++) {
	{
		my $F = $FLAG_ITER;
		my $first_time = 1;
		foreach my $R (keys %RECIPE_def) {

			if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
				next;
			}
			if ((exists $USABLE{$E}{$R}) == 0) {
				next;
			}

			if ($USABLE{$E}{$R} eq "YES") {
				next;
			}

			if ($first_time == 0) {
				print FLP " + ";
			}
			$first_time = 0;
			printf FLP "%.4f ", 1.0 / $RECIPE_FLAG_lot{$R}{$F};
			print FLP "X_$E";
			print FLP "_$R";
			print FLP "_$F";
		}
		if ($first_time == 0) {
			print FLP " - PILOT_$E = 0;\n";

			# pilot3 = max {0, pilot-3}
			print FLP "PILOT3_$E >= 0;\n";
			print FLP "PILOT3_$E - PILOT_$E >= - 3;\n";
			# pilot4 = max {0, pilot-4}
			print FLP "PILOT4_$E >= 0;\n";
			print FLP "PILOT4_$E - PILOT_$E >= - 4;\n";
		}
	}}

	# for each EQPID and FLAG, compute total lot
	foreach my $E (keys %EQPID_def) {
		my $first_time = 1;
		foreach my $R (keys %RECIPE_def) {
		for (my $F = 1; $F <= $FLAG_ITER; $F ++) {

			if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
				next;
			}
			if ((exists $USABLE{$E}{$R}) == 0) {
				next;
			}

			if ($first_time == 0) {
				print FLP " + ";
			}
			$first_time = 0;
			print FLP "X_$E";
			print FLP "_$R";
			print FLP "_$F";
		}}
		if ($first_time == 0) {
			print FLP " - T_$E = 0;\n";
			#print FLP "T_$E >= MINTIME;\n";
			#print FLP "T_$E <= MAXTIME;\n";

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
	}

	print FLP "- WEIGHT";
	foreach my $E (keys %EQPID_def) {
		foreach my $R (keys %RECIPE_def) {
		for (my $F = 1; $F <= $FLAG_ITER; $F ++) {

			if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
				next;
			}
			if ((exists $USABLE{$E}{$R}) == 0) {
				next;
			}

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
			goto next_EQPID;
		}}
		next_EQPID:;
	}
	print FLP " = 0;\n";

	close FLP;
}
	
########################################################
# read LP solution
sub read_LP {
	open (FIN, $SOLUTION_FILE) or die "Can't open $SOLUTION_FILE";

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
my %LOAD;	# EQPID -> number of lots assgined so far
sub update_LOAD {

	my $F = $_[0];

	if ($F == 0) {
		foreach my $E (keys %EQPID_def) {
			$LOAD{$E} = 0;
		}
		return;
	}

	foreach my $E (keys %EQPID_def) {
	foreach my $R (keys %RECIPE_def) {
		if (exists $PRE_ASSIGN{$E}{$R}{$F}) {
			$LOAD{$E} += $PRE_ASSIGN{$E}{$R}{$F};
		}
	}}
}
#############################################################
sub merge_largest_recipe {	# return 0: nothing to merge, 1: merged
	my $F = $_[0];

	# step 1, find the largest split recipe
	my $R_largest;	# largest split recipe
	my $L_largest = 0;	# number of lots of largest recipe

	foreach my $R (keys %RECIPE_def) {
		my $e_cnt = 0;
		foreach my $E (keys %EQPID_def) {
			if (exists $ASSIGN{$E}{$R}{$F} == 0) {
				next;
			}
			if ($ASSIGN{$E}{$R}{$F} == 0) {
				next;
			}
			$e_cnt ++;
		}

		if ($e_cnt < 2) {	# if recipe is not split, skip
			next;
		}

		if ($DEBUG) {
			print FDEBUG "$R,$RECIPE_FLAG_lot{$R}{$F}\n";
		}

		if ($RECIPE_FLAG_lot{$R}{$F} > $L_largest) {
			$R_largest = $R;
			$L_largest = $RECIPE_FLAG_lot{$R}{$F};
		}
	}

	if ($L_largest == 0) {
		return 0;
	}

	if ($DEBUG) {
		print FDEBUG "largest recipe = $R_largest, number of lots = $L_largest\n";
	}

	#  step 2, sort EQPIDs according to lots already assigned
	my @E_list;	# EQPID
	my @E_load;	# number of lots already assigned
	foreach my $E (keys %EQPID_def) {
		if (	(exists $ASSIGN{$E}{$R_largest}{$F} == 0) ||
			($ASSIGN{$E}{$R_largest}{$F} == 0)) {
				next;
		}
	
		push @E_list, $E;

		my $load2 = $LOAD{$E};
		foreach my $R (keys %RECIPE_def) {
			if ($R eq $R_largest) {
				next;
			}
			if (exists $ASSIGN{$E}{$R}{$F}) {
				$load2 += $ASSIGN{$E}{$R}{$F};
			}
		}
		push @E_load, $load2;

		if ($DEBUG) {
			print FDEBUG "\tEQPID=$E,FLAG=$F,ASSIGN=$ASSIGN{$E}{$R_largest}{$F},LOAD=$load2,";
			if ($USABLE{$E}{$R_largest} eq "NO") {
				print FDEBUG "pilot";
			}
			print FDEBUG "\n";
		}
	}
	my @idx = sort { $E_load[$a] <=> $E_load[$b] } 0 .. $#E_load;
	@E_list = @E_list[@idx];
	@E_load = @E_load[@idx];

for (my $i = 0; $i < @idx; $i ++) {
print FDEBUG "E_list = $E_list[$i],E_load = $E_load[$i]\n";
}
	# step 3, choose an EQPID with min load and not pilot
	my $target = 0;	# first one, fewest lots

	for (my $i = 0; $i < @idx; $i ++) {
		if ($i == $target) {
			if ($DEBUG) {
				print FDEBUG "pre-assign $E_list[$i] with $RECIPE_FLAG_lot{$R_largest}{$F}\n";
			}
			$ASSIGN{$E_list[$i]}{$R_largest}{$F}
				= $RECIPE_FLAG_lot{$R_largest}{$F};
			$PRE_ASSIGN{$E_list[$i]}{$R_largest}{$F}
				= $RECIPE_FLAG_lot{$R_largest}{$F};
			next;
		}
		$PRE_ASSIGN{$E_list[$i]}{$R_largest}{$F} = 0;
		$ASSIGN{$E_list[$i]}{$R_largest}{$F} = 0;
	}

	return 1;
}
##############################################################
# compute number of lots already assigned to each EQPID
my %lots_assigned;	# EQPID -> lots assigned, including this flag
my %pilot_assigned;	# EQPID -> pilots assigned only for this flag

sub compute_LOAD {

	my $FLAG_ITER = $_[0];

	undef %lots_assigned;
	undef %pilot_assigned;

	foreach my $E (keys %EQPID_def) {
		$lots_assigned{$E} = 0;
		$pilot_assigned{$E} = 0;
		foreach my $R (keys %RECIPE_def) {
		for (my $F = 1; $F <= $FLAG_ITER; $F ++) {
			if (exists $ASSIGN{$E}{$R}{$F}) {
				$lots_assigned{$E} += $ASSIGN{$E}{$R}{$F};
				if (($F == $FLAG_ITER) && ($USABLE{$E}{$R} eq "NO")) {
					$pilot_assigned{$E} ++;
				}
			}
		}}
		if ($DEBUG) {
			print FDEBUG "$E,$lots_assigned{$E},$pilot_assigned{$E}\n";
		}
	}
}
##############################################################
sub merge_small {

	my $FLAG_ITER = $_[0];
	compute_LOAD ($FLAG_ITER);

	foreach my $R (keys %RECIPE_def) {
		my @E_list;
		my @E_load;

		foreach my $E (keys %EQPID_def) {
			if ((exists $ASSIGN{$E}{$R}{$FLAG_ITER}) == 0) {
				next;
			}
			if ($ASSIGN{$E}{$R}{$FLAG_ITER} == 0) {
				next;
			}
			push @E_list, $E;
			push @E_load, $lots_assigned{$E};
		}

		if ($#E_list < 1) {	# recipe is not split, skip
			next;
		}

		my @idx = sort { $E_load[$a] <=> $E_load[$b] } 0 .. $#E_load;
		@E_list = @E_list[@idx];
		@E_load = @E_load[@idx];

		for (my $i = 1; $i < @E_list; $i ++) {
			if ($DEBUG) {
				print FDEBUG "merge_small: recipe=$R lots=$RECIPE_FLAG_lot{$R}{$FLAG_ITER}\n";
				print FDEBUG "merge_small: from=$E_list[$i] load=$E_load[$i] pilot=$pilot_assigned{$E_list[$i]}\n";
				print FDEBUG "merge_small: to=$E_list[0] load=$E_load[0] pilot=$pilot_assigned{$E_list[0]}\n";
			}
			$ASSIGN{$E_list[0]}{$R}{$FLAG_ITER} = $ASSIGN{$E_list[$i]}{$R}{$FLAG_ITER};
			$ASSIGN{$E_list[$i]}{$R}{$FLAG_ITER} = 0;
		}
	}
}

#
#			print "\tRECIPE=$R_list[$i],EQPID=$E,FLAG=$FLAG_ITER,LOT=$ASSIGN{$E}{$R_list[$i]}{$FLAG_ITER},";
#			if ($USABLE{$E}{$R_list[$i]} eq "NO") {
#				print "PILOT";
#			}
#			print "\n";
#		}
#
#		for (my $j = 0; $j < @E_list; $j ++) {
#		if ($USABLE{$E_list[$j]}{$R_list[$i]} eq "YES") {
#			# move all EQPIDs to $j
#			for (my $k = 0; $k < @E_list; $k ++) {
#				if ($k == $j) {
#					next;
#				}
#				print "merge $E_list[$k] to $E_list[$j]\n";
#				$ASSIGN{$E_list[$j]}{$R_list[$i]}{$F}
#					+= $ASSIGN{$E_list[$k]}{$R_list[$i]}{$F};
#				$load{$E_list[$j]} += $ASSIGN{$E_list[$k]}{$R_list[$i]}{$F};
#				$load{$E_list[$i]} -= $ASSIGN{$E_list[$k]}{$R_list[$i]}{$F};
#				$ASSIGN{$E_list[$k]}{$R_list[$i]}{$F} = 0;
#				goto after_merge1;
#			}
#		}}
#			print "Error! No YES is found\n";
#	
#			after_merge1:;
#		}
#	
#		print "merge to EQPIDs with fewer lots\n";
#		for (my $i = @R_list - 1; $i >= 0; $i --) {	# from more lots to fewer lots
#	
#			if ($R_pilot[$i] > 0) {
#				#next;
#			}
#	
#			print "$R_list[$i],$R_lots[$i],$R_pilot[$i]\n";
#	
#			my @E_list;
#			my @E_load;
#	
#			foreach my $E (keys %EQPID_def) {
#				if ((exists $ASSIGN{$E}{$R_list[$i]}{$F}) == 0) {
#					next;
#				}
#				if ($ASSIGN{$E}{$R_list[$i]}{$F} == 0) {
#					next;
#				}
#				push @E_list, $E;
#			push @E_load, $load{$E};
#	
#				print "\tRECIPE=$R_list[$i],EQPID=$E,FLAG=$F,LOT=$ASSIGN{$E}{$R_list[$i]}{$F},";
#				if ($USABLE{$E}{$R_list[$i]} eq "NO") {
#					print "PILOT";
#				}
#				print "\n";
#			}
#			my @idx = sort { $E_load[$a] <=> $E_load[$b] } 0 .. $#E_load;
#			@E_list = @E_list[@idx];
#			@E_load = @E_load[@idx];
#	
#			for (my $k = 1; $k < @E_list; $k ++) {
#				print "merge $E_list[$k] of load $load{$E_list[$k]} to $E_list[0] of load $load{$E_list[0]}\n";
#				$ASSIGN{$E_list[0]}{$R_list[$i]}{$F}
#					+= $ASSIGN{$E_list[$k]}{$R_list[$i]}{$F};
#				$load{$E_list[0]} += $ASSIGN{$E_list[$k]}{$R_list[$i]}{$F};
#				$load{$E_list[$k]} -= $ASSIGN{$E_list[$k]}{$R_list[$i]}{$F};
#				$ASSIGN{$E_list[$k]}{$R_list[$i]}{$F} = 0;
#				print "now $E_list[$k] has load $load{$E_list[$k]} and $E_list[0] has load $load{$E_list[0]}\n";
#				$PRE_ASSIGN{$E_list[0]}{$R_list[$i]}{$F} = $ASSIGN{$E_list[0]}{$R_list[$i]}{$F};
#				$PRE_ASSIGN{$E_list[$k]}{$R_list[$i]}{$F} = 0;
#			}
#		}
#	}
#########################################################
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
	my $F = $_[0];

	foreach my $E (keys %EQPID_def) {
		# compute number of lots assigned at this flag
		my $lots = 0;
		foreach my $R (keys %RECIPE_def) {
			if (exists $ASSIGN{$E}{$R}{$F}) {
				$lots += $ASSIGN{$E}{$R}{$F};
			}
		}

		my $idle = int ($AVE_LOT_ACC[$F] - ($LOAD{$E} + $lots + $BUFFER_SIZE));
		if ($idle < 0) {
			next;
		}

		$ASSIGN{$E}{"IDLE"}{$F} = $idle;
		$PRE_ASSIGN{$E}{"IDLE"}{$F} = $idle;

		if ($DEBUG) {
			print FDEBUG "-----> F = $F\tE = $E busy = $lots, ave = $AVE_LOT_ACC[$F], idle = $idle\n";
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
			if ($USABLE{$E}{$R} eq "NO") {
				$USABLE{$E}{$E} = "YES";
				if ($DEBUG) {
					print FDEBUG "PILOT updated $E $R\n";
				}
			}
		}
	}}
}
#########################################################
#main
{
	read_INPUT;
	update_LOAD (0);

	for (my $FLAG_ITER = 1; $FLAG_ITER <= $FLAG_MAX; $FLAG_ITER ++) {
		for (my $i = 0; $i < 10; $i ++)
		{
			undef %ASSIGN;
			#print_USABLE;
			gen_LP ($FLAG_ITER);
			system ("$LP_SOLVE $LP_FILE > $SOLUTION_FILE");
			if (read_LP == 0) {
				exit;
			}
			#system ("mv LP.lp LP$i.lp");
			#system ("mv solution.txt solution$i.txt");
			#system ("mv solution.csv solution$i.csv");
			if (merge_largest_recipe ($FLAG_ITER) == 0) {
				last;
			}
	print_SOLUTION_MATRIX;
	print_SOLUTION_RECIPE_EQPID;
	print_SOLUTION_EQPID_RECIPE;
exit;
			write_PRE_ASSIGN ($FLAG_ITER);
		}
		merge_small ($FLAG_ITER);
if ($FLAG_ITER == 3) {
goto xxx;
}
		write_ASSIGN_IDLE ($FLAG_ITER);
		update_USABLE ($FLAG_ITER);
		update_LOAD ($FLAG_ITER);
	}
	xxx:;
	print_SOLUTION_MATRIX;
	print_SOLUTION_RECIPE_EQPID;
	print_SOLUTION_EQPID_RECIPE;
}
#########################################################
