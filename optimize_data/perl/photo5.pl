#!/usr/bin/perl
use strict;
########################################################
#my $INPUT_FILE= "../Data/ILI_debug.csv";
my $INPUT_FILE= "../data/DUV.csv";
my $LP_FILE = "LP.lp";
#my $LP_SOLVE = 'cygdrive/d/ProgramFiles/LPSolve IDE/LpSolveIDE.exe';
my $LP_SOLVE = '/cygdrive/d/workspace/lp_source/lp_solve_5.5/lp_solve/bin/ux64/lp_solve.exe';
my $SOLUTION_TXT_FILE = "solution.txt";
my $SOLUTION_CSV_FILE = "solution.csv";
my $DEBUG_FILE = "debug.txt";
########################################################
#my $GOAL = "MIN_MAXTIME";
#my $GOAL = "MAX_MINTIME";
#my $GOAL = "MIN_GAP";		# not a good apporach
#my $GOAL = "MIN_PILOTLIMITEQPIDFLAG";
my $GOAL = "MIN_SUMDIF";	# SUMDIF = sum_EQPID max {TIME-AVE_TIME, 0} }
my $DEBUG = 1;			# 0/1: to print debug info
if ($DEBUG) {
	open (FDEBUG, ">", $DEBUG_FILE) or die "Can't open $DEBUG_FILE";
}
########################################################
# processing time for C wafers of a lot = A + B * C
my $CONST_A = 0;
my $CONST_B = 1/25;
my $FLAG_MAX = 6;

#my $MAX_TIME_LIMIT = 1000;	# can be adjusted, not used now
my @AVE_TIME;			# FLAG -> ave for this flag
my @AVE_TIME_ACC;		# FLAG -> ave for flag 1 to this flag
my $PILOT_LIMIT_FLAG = 100;	# pilots of each flag, can be adjusted
my $PILOT_LIMIT_EQPID_FLAG = 5; # pilots of each flag and each EQPID, can be adjusted
my $PENALTY_PILOT_GT_3 = 0.1;
my $PENALTY_PILOT_GT_4 = 10;
my $BUFFER_SIZE = 5;		# if lot < AVE - BUFFER_SIZE, will assign IDLE
########################################################
my %LOTID_def;		# LOTID -> 1
my %EQPID_def;		# EQPID -> 1
my %RECIPE_def;		# RECIPE -> 1
	$RECIPE_def{"IDLE"} = 1;
my %RECIPE_FLAG_lot;	# (RECIPE,FLAG) -> number of lots
my %USABLE;		# (EQPID, RECIPE) -> YES, NO, blank
my %ASSIGN;		# (EQPID, RECIPE, FLAG) -> lots, LP solution
my %PRE_ASSIGN;		# (EQPID, RECIPE, FLAG) -> value
########################################################
# read input file
sub read_INPUT {
	open (FIN, $INPUT_FILE) or die "Can't open $INPUT_FILE";
	my $header = <FIN>;	# skip header

	# LOTID,ECSEQ,PAS STATUS,COMING FLAG,RETICLE,QTY
	# DFP780.01,BPILI33,NO,1,8824ZERO-PHOTO,1

	while (my $line = <FIN>) {
		chomp ($line); $line =~ s/\"//g; $line =~ s///g;
		(my @fields) = split (",", $line);

		my $LOTID = $fields[0];
		my $EQPID = $fields[1];
		my $PAS = $fields[2];
		my $FLAG = $fields[3];
		my $RECIPE = $fields[4];
		if ($RECIPE eq "") {
			next;
		}
		if (grep (/^X/, $RECIPE)) {	# skip X lots
			next;
		}
		$RECIPE =~ s/-//g;	# remove - for LP solver

		my $WAFER = $fields[5];
		#my $lot = $CONST_A + $CONST_B * $WAFER;
		my $lot = 0;
		if ($WAFER >= 24) {
			$lot = 1;
		} elsif ($WAFER >= 18) {
			$lot = 0.75;
		} elsif ($WAFER >= 12) {
			$lot = 0.5;
		} else {
			$lot = 0.25;
		}

		$EQPID_def{$EQPID} = 1;
		$RECIPE_def{$RECIPE} = 1;

		if (exists $USABLE{$EQPID}{$RECIPE}) {
			if ($USABLE{$EQPID}{$RECIPE} ne $PAS) {
				if ($DEBUG) {
					print FDEBUG "Warning: $RECIPE pilot definition inconsistent, treated as YES\n";
				}
				$USABLE{$EQPID}{$RECIPE} = "YES";	# inconsistent PILOT treat as YES
			}
		} else {
			$USABLE{$EQPID}{$RECIPE} = $PAS;
		}

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

	# compute average time for each flag
	{
		my $e_cnt = 0;
		foreach my $E (keys %EQPID_def) {
			$e_cnt ++;
		}

		my @l_cnt;
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			$l_cnt[$F] = 0;
		}

		foreach my $R (keys %RECIPE_FLAG_lot) {
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			if (exists $RECIPE_FLAG_lot{$R}{$F}) {
				$l_cnt[$F] += $RECIPE_FLAG_lot{$R}{$F};
			}
		}}

		$AVE_TIME_ACC[0] = 0;

		if ($DEBUG) {
			print FDEBUG "\n";
		}

		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			$AVE_TIME[$F] = $l_cnt[$F] / $e_cnt;
			$AVE_TIME_ACC[$F] = $AVE_TIME_ACC[$F-1] + $l_cnt[$F] / $e_cnt;

			if ($DEBUG) {
				print FDEBUG "F=$F,AVE_TIME=$AVE_TIME[$F],AVE_TIME_ACC=$AVE_TIME_ACC[$F]\n";
			}
		}
	}
}
########################################################
# print number of lots and usable matrix
sub print_USABLE {
	
	open (FOUT, ">usable.csv") or die "Can't open usable.csv";

	print FOUT "RECIPE,";
	for (my $F = 1; $F <= $FLAG_MAX ; $F ++) {
		print FOUT "$F,";
	}

	foreach my $E (keys %EQPID_def) {
		print FOUT "$E,";
	}
	print FOUT "\n";

	foreach my $R (keys %RECIPE_def) {
		print FOUT "$R,";
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			if (exists $RECIPE_FLAG_lot{$R}{$F}) {
				print FOUT "$RECIPE_FLAG_lot{$R}{$F},";
			} else {
				print FOUT ",";
			}
		}

		foreach my $E (keys %EQPID_def) {
			print FOUT "$USABLE{$E}{$R},";
		}
		print FOUT "\n";
	}
	close FOUT;
}
########################################################
sub print_SOLUTION_MATRIX {

	my $print_PILOT = 0;

	open (FOUT, ">assign.csv") or die "Can't open assign.csv";

	print FOUT "EQPID,";
	for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
		print FOUT "lot($F),";
		if ($print_PILOT) {
			print FOUT "pilot($F),";
		}
	}
	print FOUT "total_lot,total_pilot\n";

	foreach my $E (keys %EQPID_def) {
		print FOUT "$E,";
		my $total_lot = 0;
		my $total_pilot = 0;
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			my $flag_lot = 0;
			my $flag_pilot = 0;
			foreach my $R (keys %RECIPE_def) {
				if ($ASSIGN{$E}{$R}{$F} > 0) {
					$flag_lot += $ASSIGN{$E}{$R}{$F};
					if ($USABLE{$E}{$R} eq "NO") {
						$flag_pilot += $ASSIGN{$E}{$R}{$F}/$RECIPE_FLAG_lot{$R}{$F};
					}
				}
			}
			printf FOUT "%.2f,", $flag_lot;
			if ($print_PILOT) {
				printf FOUT "%d,", $flag_pilot;
			}
			$total_lot += $flag_lot;
			$total_pilot += $flag_pilot;
		}
		printf FOUT "%.2f,%d\n", $total_lot, $total_pilot;
	}
	close FOUT;
}
########################################################
sub print_SOLUTION_EQPID_RECIPE {

	open (FOUT, ">eqpid_recipe.csv") or die "Can't open assign.csv";

	print FOUT "EQPID,RECIPE,FLAG,LOT,PILOT\n";

	foreach my $E (keys %EQPID_def) {
		my $total_lot = 0;
		my $total_pilot = 0;

		#print FOUT "----------\n";
		foreach my $R (keys %RECIPE_def) {
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
			if ((exists $ASSIGN{$E}{$R}{$F}) == 0) {
				next;
			}
			if ($ASSIGN{$E}{$R}{$F} == 0) {
				next;
			}
			$total_lot += $ASSIGN{$E}{$R}{$F};
			#print FOUT "\trecipe=$R, flag=$F, lot=$ASSIGN{$E}{$R}{$F}";
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
		#print FOUT "EQPID=$E,total_lot=$total_lot, total_pilot=$total_pilot\n";
	}

	close FOUT;
}
########################################################
sub print_SOLUTION_RECIPE_EQPID {

	open (FOUT, ">recipe_eqpid.csv") or die "Can't open assign.csv";

	foreach my $R (keys %RECIPE_def) {

		print FOUT "RECIPE=$R\n";
		foreach my $E (keys %EQPID_def) {
		for (my $F = 1; $F <= $FLAG_MAX; $F ++) {
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
	# generate LP input file from FLAG=1 till FLAG=FLAG_ITER
	sub gen_LP {
		my $FLAG_ITER = $_[0];
	
		open (FLP, ">", $LP_FILE) or die "Can't open $LP_FILE";
	
		# objective function
		if ($GOAL eq "MIN_MAXTIME") {
			print FLP "min: MAXTIME;\n";
		} elsif ($GOAL eq "MAX_MINTIME") {
			print FLP "min: -MINTIME;\n";
		} elsif ($GOAL eq "MIN_PILOTLIMITEQPIDFLAG") {
			print FLP "min: PILOTLIMITEQPIDFLAG;\n";
		} elsif ($GOAL eq "MIN_SUMDIF") {
			print FLP "min: SUMDIF;\n";
		}
	
		#printf FLP "MINTIME >= %d;\n", $AVE_TIME[$FLAG_ITER]-1.5;
		#print FLP "MINTIME >= $MIN_TIME_LIMIT;\n";
		#print FLP "MAXTIME <= $MAX_TIME_LIMIT;\n";
		print FLP "PILOTLIMITEQPIDFLAG <= $PILOT_LIMIT_EQPID_FLAG;\n";
	
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
		{
			my $F = $FLAG_ITER;
	
			my $first_time = 1;
	
			foreach my $E (keys %EQPID_def) {
			foreach my $R (keys %RECIPE_def) {
	
				if ((exists $RECIPE_FLAG_lot{$R}{$F}) == 0) {
					next;
				}
				if (exists $USABLE{$E}{$R} == 0) {
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
			}}
	
			if ($first_time == 0) {
				print FLP " <= $PILOT_LIMIT_FLAG;\n";
			}
		}

		# for each EQPID and FLAG, compute total pilot
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
				print FLP "PILOT3_$E - PILOT_$E - 3 >= 0;\n";
				# pilot4 = max {0, pilot-4}
				print FLP "PILOT4_$E >= 0;\n";
				print FLP "PILOT4_$E - PILOT_$E - 4 >= 0;\n";
				#print FLP " <= PILOTLIMITEQPIDFLAG;\n";
			}
		}}
	
		# for each EQPID, total time must be less than MAXTIME and greater than MINTIME
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

				if ($GOAL eq "MIN_SUMDIF") {
					# DIF1 = max {0.7*AVE - T_E, 0}
					print FLP "DIF1_$E >= 0;\n";
					printf FLP "DIF1_$E + T_$E >= %d;\n", $AVE_TIME_ACC[$FLAG_ITER-1] + 0.7 * $AVE_TIME[$FLAG_ITER];
					# DIF2 = max {AVE - T_E, 0}
					print FLP "DIF2_$E >= 0;\n";
					printf FLP "DIF2_$E + T_$E >= %d;\n", $AVE_TIME_ACC[$FLAG_ITER-1] + 1.0 * $AVE_TIME[$FLAG_ITER];
					# DIF3 = max {1.2*AVE - T_E, 0}
					print FLP "DIF3_$E >= 0;\n";
					printf FLP "DIF3_$E + T_$E >= %d;\n", $AVE_TIME_ACC[$FLAG_ITER-1] + 1.25 * $AVE_TIME[$FLAG_ITER];
					# DIF4 = max {1.5*AVE - T_E, 0}
					print FLP "DIF4_$E >= 0;\n";
					printf FLP "DIF4_$E + T_$E >= %d;\n", $AVE_TIME_ACC[$FLAG_ITER-1] + 1.5 * $AVE_TIME[$FLAG_ITER];
					# DIF5 = max {T_E + 2.0*AVE, 0}
					print FLP "DIF5_$E >= 0;\n";
					printf FLP "DIF5_$E - T_$E - %d >= 0;\n", 1.5*$AVE_TIME_ACC[$FLAG_ITER];
				}
			}
		}
	
		if ($GOAL eq "MIN_SUMDIF") {
			print FLP "- SUMDIF";
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
					print FLP " + 3.0 DIF1_$E + 1.0 DIF2_$E + 0.5 DIF3_$E + 0.2 DIF4_$E + 0.5 DIF5_$E";
					goto next_EQPID;
				}}
				next_EQPID:;
			}
			print FLP " = 0;\n";
		}
	
		close FLP;
	}
	
########################################################
# run LP
sub run_LP {
	system ("$LP_SOLVE $LP_FILE > $SOLUTION_TXT_FILE");
	system ("sed s/X_// $SOLUTION_TXT_FILE | sed \"s/  */,/\" | sed \"s/Value.\*//\" | sed \"s/Actual.\*//\" | sed \"s/.\*,0\$//\" | sed \"s/^T_.*//\" | sed \"s/^DIF.*//\" | sed \"s/^PILOT.*//\" | sed s/_/,/g | sort -u > $SOLUTION_CSV_FILE"); 
}
#########################################################
# read LP solution
sub read_LP {
	open (FIN, $SOLUTION_CSV_FILE) or die "Can't open $SOLUTION_CSV_FILE";
	my $toss = <FIN>;	# delete first empty line

	if (grep (/This,problem is infeasible/, $toss)) {
		print "This problem is infeasible\n";
		return 0;
	}

	# EQPID,RECIPE,FLAG,VALUE
	while (my $line = <FIN>) {
		chomp ($line); $line =~ s/\"//g; $line =~ s///g;
		(my @fields) = split (",", $line);

		if ($fields[0] eq "") {
			next;
		}

		#if ($fields[0] eq "MAXTIME") {
		#	if ($GOAL eq "MIN_MAXTIME") {
		#		print "MAXTIME = $fields[1]\n";
		#	}
		#	next;
		#}
		
		if ($fields[0] eq "MINTIME") {
			if ($GOAL eq "MAX_MINTIME") {
				print FDEBUG "MINTIME = $fields[1]\n";
			}
			next;
		}
		if ($fields[0] eq "PILOTLIMITEQPIDFLAG") {
			if ($GOAL eq "MIN_PILOTMILITEQPIDFLAG") {
				print FDEBUG "PILOT = $fields[1]\n";
			}
			next;
		}

		if ($fields[0] eq "SUMDIF") {
			if ($GOAL eq "MIN_SUMDIF") {
				print FDEBUG "SUMDIF = $fields[1]\n";
			}
			next;
		}
		$ASSIGN{$fields[0]}{$fields[1]}{$fields[2]} = $fields[3];
	}
	close FIN;
}
#############################################################
sub merge_largest_recipe {	# return 0: nothing to merge, 1: merged
	my $FLAG_ITER = $_[0];

	# step 1, find the largest recipe
	my $R_largest;	# largest split recipe
	my $L_largest;	# number of lots of largest recipe

	foreach my $R (keys %RECIPE_def) {
		my $e_cnt = 0;
		foreach my $E (keys %EQPID_def) {
			if (exists $ASSIGN{$E}{$R}{$FLAG_ITER} == 0) {
				next;
			}
			if ($ASSIGN{$E}{$R}{$FLAG_ITER} == 0) {
				next;
			}
			$e_cnt ++;
		}

		if ($e_cnt < 2) {	# if recipe is not split, skip
			next;
		}

		if ($DEBUG) {
			print FDEBUG "$R,$RECIPE_FLAG_lot{$R}{$FLAG_ITER}\n";
		}

		if ($RECIPE_FLAG_lot{$R}{$FLAG_ITER} > $L_largest) {
			$R_largest = $R;
			$L_largest = $RECIPE_FLAG_lot{$R}{$FLAG_ITER};
		}
	}

	if ($R_largest eq "") {
		#print "R_largest is empty, $L_largest\n";
		return 0;
	}
	
	if ($DEBUG) {
		print FDEBUG "largest: $R_largest,$L_largest\n";
	}

	#  step 2, sort EQPIDs according to lots assigned
	my @E_list;	# list of EQPID
	my @E_lots;	# number of lots
	foreach my $E (keys %EQPID_def) {
		if ((exists $ASSIGN{$E}{$R_largest}{$FLAG_ITER}) == 0) {
			next;
		}
		if ($ASSIGN{$E}{$R_largest}{$FLAG_ITER} == 0) {
			next;
		}
		push @E_list, $E;
		push @E_lots, $ASSIGN{$E}{$R_largest}{$FLAG_ITER};

		if ($DEBUG) {
			print FDEBUG "\tEQPID=$E,FLAG=$FLAG_ITER,LOT=$ASSIGN{$E}{$R_largest}{$FLAG_ITER}\n";
		}
	}
	my @idx = sort { $E_lots[$a] <=> $E_lots[$b] } 0 .. $#E_lots;
	@E_list = @E_list[@idx];
	@E_lots = @E_lots[@idx];

	# step 3, choose an EQPID with largest lots and not pilot
	my $target = @idx - 1;
	for (my $i = $target; $i >= 0; $i --) {
		if ($USABLE{$E_list[$i]}{$R_largest} eq "YES") {
			$target = $i;
			last;
		}
	}
	for (my $i = 0; $i < @idx; $i ++) {
		if ($i == $target) {
			if ($DEBUG) {
				print FDEBUG "pre-assign $E_list[$i] with $RECIPE_FLAG_lot{$R_largest}{$FLAG_ITER}\n";
			}
			$PRE_ASSIGN{$E_list[$i]}{$R_largest}{$FLAG_ITER}
				= $RECIPE_FLAG_lot{$R_largest}{$FLAG_ITER};
			next;
		}
		$PRE_ASSIGN{$E_list[$i]}{$R_largest}{$FLAG_ITER} = 0;
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
			my $a = 0.25 * int ($ASSIGN{$E}{$R}{$F} * 4) ;
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
		my $lots = 0;
		foreach my $R (keys %RECIPE_def) {
		for (my $F = 1; $F <= $FLAG_ITER; $F ++) {
			if (exists $ASSIGN{$E}{$R}{$F}) {
				$lots += $ASSIGN{$E}{$R}{$F};
			}
		}}

		if ($lots + $BUFFER_SIZE > $AVE_TIME_ACC[$FLAG_ITER]) {
			next;
		}


		my $idle = int ($AVE_TIME_ACC[$FLAG_ITER] - $lots - $BUFFER_SIZE);

		$ASSIGN{$E}{"IDLE"}{$FLAG_ITER} = $idle;
		$PRE_ASSIGN{$E}{"IDLE"}{$FLAG_ITER} = $idle;

		if ($DEBUG) {
			print FDEBUG "-----> F = $FLAG_ITER\tE = $E busy = $lots, ave = $AVE_TIME_ACC[$FLAG_ITER], idle = $idle\n";
		}
	}
}
#########################################################
sub update_USABLE {
	my $FLAG_ITER = $_[0];

	foreach my $E (keys %ASSIGN) {
	foreach my $R (keys %{$ASSIGN{$E}}) {
		if ($R eq "IDLE") {
			next;
		}
		if (exists $ASSIGN{$E}{$R}{$FLAG_ITER}) {
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
# main
{
	read_INPUT;
	for (my $FLAG_ITER = 1; $FLAG_ITER <= $FLAG_MAX; $FLAG_ITER ++) {
		for (my $i = 0; $i < 10; $i ++)
		{
			undef %ASSIGN;
			#print_USABLE;
			gen_LP ($FLAG_ITER);
			run_LP;
			if (read_LP == 0) {
				exit;
			}
			#system ("mv LP.lp LP$i.lp");
			#system ("mv solution.txt solution$i.txt");
			#system ("mv solution.csv solution$i.csv");

			if (merge_largest_recipe ($FLAG_ITER) == 0) {
				last;
			}
			write_PRE_ASSIGN ($FLAG_ITER);
		}
		merge_small ($FLAG_ITER);
		write_ASSIGN_IDLE ($FLAG_ITER);
		update_USABLE ($FLAG_ITER);
	}
	print_SOLUTION_MATRIX;
	print_SOLUTION_RECIPE_EQPID;
	print_SOLUTION_EQPID_RECIPE;
}
#########################################################
