#!/usr/bin/perl
use strict;
use Storable qw(dclone);
####################################
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
		chomp ($line); $line =~ s/\"//g; $line =~ s///g;
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


my $max_total_lot_score = 100;
sub ave_lot_score {

	my $AVE = $_[0];	# computed by (total lots from time=0 to now) / (number of machines)
	my $ASSIGNED = $_[1];	# number of lots assgigned from flag=1 to now by you

    #return abs($AVE - $ASSIGNED);
	if (abs($AVE - $ASSIGNED) < 3) {
		return 0;
	}

	if (abs($AVE - $ASSIGNED) == 3) {
		return 1;
	}

	if (abs($AVE - $ASSIGNED) == 4) {
		return 2;
	}

	return 10;
}

my $max_total_pilot_score = 110;
sub ave_pilot_score {

	my $THRESHOLD = $_[0];	# assume 3, given by user
	my $ASSIGNED = $_[1];

	if ($THRESHOLD >= $ASSIGNED) {
		return 0;
	}

	if ($THRESHOLD == $ASSIGNED+1){
		return 5;
	}
	return 100;
}

#my $ER_FILE="../data/eqpid_recipe.csv";
my $ER_FILE="./eqpid_recipe_lot_pilot.csv";
my %ER_ASSIGN;		  # (EQPID, FLAG, RECIPE) -> [lot,pilot]
my %EF_COUNT;		  # (EQPID, FLAG) -> [lots,pilots]
my %HANDLE_ER_ASSIGN; # (EQPID, RECIPE, FLAG) -> [lot,pilot] deault should be %ER_ASSIGN's deep copy
my %HANDLE_EF_COUNT;  # (EQPID, FLAG) -> [lots,pilots] deault should be %EF_COUNT's deep copy
#my @EF_COUNT_STORE;   # store %EF_COUNT per ascending order with lots
my $OP_FLAG = 1;
my $final_score;      #store the final total score(lot_score+pilot_score)
my $switch_cnt = 0;   #recore switch count
sub read_ER_FILE{
  open(FIN, $ER_FILE) or die "Can't open $ER_FILE";
  my $header = <FIN>;	# skip header

  # EQPID	RECIPE  	FLAG	LOT	PILOT
  # APDI708	6445P1PHOTO	1		6.25	pilot

  while (my $line = <FIN>) {
    chomp ($line); $line =~ s/\"//g; $line =~ s///g;
    (my @fields) = split (",", $line);
    
    my $EQPID = $fields[0];
    my $RECIPE = $fields[1];
    my $FLAG = $fields[2];
    my $LOT = $fields[3];
    my $PILOT = 0;
    if($fields[4] =~ /^\s*pilot\s*$/i){
      $PILOT = 1;
    }

    $ER_ASSIGN{$EQPID}{$FLAG}{$RECIPE}=[$LOT,$PILOT];
    #print("$line\n");
    #print("--$LOT,$PILOT\n");
    #print("$ER_ASSIGN{$EQPID}{$FLAG}{$RECIPE}[0]\n");
    #print("==@{$ER_ASSIGN{$EQPID}{$FLAG}{$RECIPE}}\n");

    if(exists $EF_COUNT{$EQPID}{$FLAG}){
      #print("+@{$EF_COUNT{$EQPID}{$FLAG}}---$LOT,$PILOT\n");
      $EF_COUNT{$EQPID}{$FLAG}=[$EF_COUNT{$EQPID}{$FLAG}[0]+$LOT,$EF_COUNT{$EQPID}{$FLAG}[1]+$PILOT];
      #print("++@{$EF_COUNT{$EQPID}{$FLAG}}\n");}
    }else{
      $EF_COUNT{$EQPID}{$FLAG}=[$LOT,$PILOT];
    }
  }
  close(FIN);
}

sub get_EQP_NUM_ON_FLAG{
  my $FLAG = $_[0];
  my $cnt = 0;
  foreach my $E (keys %HANDLE_EF_COUNT){
    foreach my $F (keys %{$HANDLE_EF_COUNT{$E}}){
      if($F eq $FLAG){
        $cnt++;
      }
    }
  }
  return $cnt;
}

sub get_ave_lot_with_flag{
  my $FLAG = $_[0];
  my $e_cnt = 0;
  my $lot_cnt = 0;
  foreach my $E (keys %HANDLE_EF_COUNT){
    foreach my $F (keys %{$HANDLE_EF_COUNT{$E}}){
      if($F <= $FLAG){
        $lot_cnt += $HANDLE_EF_COUNT{$E}{$F}[0];
      }
    }
  }
  return $lot_cnt/get_EQP_NUM_ON_FLAG($FLAG);
}


sub get_total_lot_score_ON_FLAG{
  my $FLAG = $_[0];
  my $lot_cnt = 0;
  my $score = 0;
  my $ave = get_ave_lot_with_flag($FLAG);
  foreach my $E (keys %HANDLE_EF_COUNT){
    $lot_cnt = 0;#static per eqpid
    foreach my $F (keys %{$HANDLE_EF_COUNT{$E}}){
      if($F <= $FLAG){
        $lot_cnt += $HANDLE_EF_COUNT{$E}{$F}[0];
      }
    }
    my $s = ave_lot_score($ave,$lot_cnt);
    $score += $s;
    #print("score $E $FLAG $ave--$lot_cnt $s\n");
  }
  return $score;
}

sub get_total_pilot_score_ON_FLAG{
  my $FLAG = $_[0];
  my $pilot_cnt = 0;
  my $score = 0;
  my $THRESHOLD = 3;
  foreach my $E (keys %HANDLE_EF_COUNT){
    $pilot_cnt = 0;#static per eqpid
    foreach my $F (keys %{$HANDLE_EF_COUNT{$E}}){
      if($F <= $FLAG){
        $pilot_cnt += $HANDLE_EF_COUNT{$E}{$F}[1];
      }
    }
    my $s = ave_pilot_score($THRESHOLD,$pilot_cnt);
    $score += $s;
    #print("score $E $FLAG $THRESHOLD--$pilot_cnt $s\n");
  }
  return $score;
}

sub switch_recipe_between_eqpid_on_flag{
  my $E1 = $_[0];
  my $E2 = $_[1];
  my $FLAG = $_[2];
  my @R_ARRAY1;
  my @R_ARRAY2;
  foreach my $R (keys %{$ER_ASSIGN{$E1}{$FLAG}}){
    push(@R_ARRAY1,$R);
  }
  foreach my $R (keys %{$ER_ASSIGN{$E2}{$FLAG}}){
    push(@R_ARRAY2,$R);
  }
  #print("@R_ARRAY1\n");
  #print("@R_ARRAY2\n");

  for(my $i = 0; $i <= $#R_ARRAY1; $i++){
    for(my $j = 0; $j <= $#R_ARRAY2; $j++){
      #print("$E1-$FLAG-$R_ARRAY1[$i]<-->$E2-$FLAG-$R_ARRAY2[$j]  $USABLE{$E1}{$R_ARRAY2[$j]}<-->$USABLE{$E2}{$R_ARRAY1[$i]}\n");
      next if($R_ARRAY1[$i]=~/^\s*IDLE\s*$/i || $R_ARRAY2[$j]=~/^\s*IDLE\s*$/i);
      next if(!(exists $USABLE{$E1}{$R_ARRAY2[$j]}) || !(exists $USABLE{$E2}{$R_ARRAY1[$i]}));
      #the recipe may be not exist on eqpid&flag,because it may be changed and deleted when reach the requirement
      next if(!(exists $ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]}) || !(exists $ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]}));
      $switch_cnt++;
      #deep copy hash as new hash data in memory
      undef %HANDLE_EF_COUNT;
      %HANDLE_EF_COUNT = %{dclone(\%EF_COUNT)};

      $HANDLE_EF_COUNT{$E1}{$FLAG}[0] = $HANDLE_EF_COUNT{$E1}{$FLAG}[0]-$ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]}[0]+$ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]}[0];
      $HANDLE_EF_COUNT{$E1}{$FLAG}[1] = $HANDLE_EF_COUNT{$E1}{$FLAG}[1]-$ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]}[1]+$USABLE{$E1}{$R_ARRAY2[$j]} eq "YES"?1:0;
      $HANDLE_EF_COUNT{$E2}{$FLAG}[0] = $HANDLE_EF_COUNT{$E2}{$FLAG}[0]-$ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]}[0]+$ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]}[0];
      $HANDLE_EF_COUNT{$E2}{$FLAG}[1] = $HANDLE_EF_COUNT{$E2}{$FLAG}[1]-$ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]}[1]+$USABLE{$E2}{$R_ARRAY1[$i]} eq "YES"?1:0;

      my $lot_score = get_total_lot_score_ON_FLAG($OP_FLAG);
      my $pilot_score = get_total_pilot_score_ON_FLAG($OP_FLAG);
      my $tmp_score = $lot_score + $pilot_score;
      next if($lot_score > $max_total_lot_score || $pilot_score > $max_total_pilot_score || $tmp_score >= $final_score);
      print("----lot_score=$lot_score pilot_score=$pilot_score  $E1-$FLAG-$R_ARRAY1[$i]<-->$E2-$FLAG-$R_ARRAY2[$j]\n");

      #changed and deleted recipe from eqpid&flag as reach the requirement
      undef %HANDLE_ER_ASSIGN;
      %HANDLE_ER_ASSIGN = %{dclone(\%ER_ASSIGN)};
      $HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY2[$j]}=[$HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]}[0],$USABLE{$E1}{$R_ARRAY2[$j]} eq "YES"?1:0];
      $HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY1[$i]}=[$HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]}[0],$USABLE{$E2}{$R_ARRAY1[$i]} eq "YES"?1:0];
      print("$E1-$FLAG-$R_ARRAY1[$i] @{$HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]}}==>$E2-$FLAG-$R_ARRAY1[$i] @{$HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY1[$i]}}\n");
      print("$E2-$FLAG-$R_ARRAY2[$j] @{$HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]}}==>$E1-$FLAG-$R_ARRAY2[$j] @{$HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY2[$j]}}\n\n");
      delete $HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]};
      delete $HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]};

      $final_score = $tmp_score;
      %EF_COUNT = %{dclone(\%HANDLE_EF_COUNT)};
      %ER_ASSIGN = %{dclone(\%HANDLE_ER_ASSIGN)};
      
    }
  }
}

sub print_ER_ASSIGN{
  open (FOUT, ">eqpid_recipe_lot_pilot.csv") or die "Can't open eqpid_recipe_lot_pilot.csv";
  print FOUT "EQPID,RECIPE,FLAG,LOT,PILOT\n";
  foreach my $E (keys %ER_ASSIGN){
    foreach my $F (keys %{$ER_ASSIGN{$E}}){
      foreach my $R (keys %{$ER_ASSIGN{$E}{$F}}){
        if($ER_ASSIGN{$E}{$F}{$R}[1] eq 1){
          print FOUT "$E,$R,$F,$ER_ASSIGN{$E}{$F}{$R}[0],pilot\n"
        }else{
          print FOUT "$E,$R,$F,$ER_ASSIGN{$E}{$F}{$R}[0],\n"
        }
      }
    }
  }
  close(FOUT);
}


read_INPUT();
#foreach my $i (keys(%USABLE)){
#  foreach my $j (keys(%{$USABLE{$i}})){
#    print("$i--$j==>$USABLE{$i}{$j}\n");
#  }
#}

read_ER_FILE();
%HANDLE_EF_COUNT=%{dclone(\%EF_COUNT)};

#foreach my $E (sort {$a cmp $b} keys %EF_COUNT){
foreach my $E (keys %EF_COUNT){
  foreach my $F (keys %{$EF_COUNT{$E}}){
    if($F <= $OP_FLAG){
      print("$E,$F-->@{$EF_COUNT{$E}{$F}}\n");
    }
  }
}


#get all flag's eqp num
#for(my $F = 1; $F <= $FLAG_MAX; $F++){
#  my $cnt = get_EQP_NUM_ON_FLAG($F);
#  print("FLAG$F:$cnt\n");
#  my $l_cnt = get_ave_lot_with_flag($F);
#  print("FLAG$F:$l_cnt\n");
#}

my $lot_score = get_total_lot_score_ON_FLAG($OP_FLAG);
my $pilot_score = get_total_pilot_score_ON_FLAG($OP_FLAG);
$final_score = $lot_score+$pilot_score;
print("FINAL:$final_score  lot_score=$lot_score pilot_score=$pilot_score\n");

#get all eqpid on flag 1
my @E_ARRAY;#for store flag1's eqpid
foreach my $E (keys %EF_COUNT){
  foreach my $F (keys %{$EF_COUNT{$E}}){
    if($F eq $OP_FLAG){
      #print("$E,$F-->@{$EF_COUNT{$E}{$F}}\n");
      push(@E_ARRAY,$E);
    }
  }
}

my $a_cnt = 0;
for(my $i = 0; $i <= $#E_ARRAY; $i++){
  for(my $j = $i+1; $j <= $#E_ARRAY; $j++){
    #print("$E_ARRAY[$i]--$E_ARRAY[$j]\n");
    switch_recipe_between_eqpid_on_flag($E_ARRAY[$i],$E_ARRAY[$j],$OP_FLAG);
    $a_cnt++;
  }
}
print("$a_cnt  $switch_cnt\n");

print_ER_ASSIGN();






