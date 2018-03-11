#!/usr/bin/perl
use strict;
use Storable qw(dclone);
####################################
my $INPUT_FILE= "../data/DUV.csv";
my $DEBUG_FILE = "debug.txt";
my $DEBUG = 1;			# 0/1: to print debug info
if ($DEBUG) {
	open (FDEBUG, ">", $DEBUG_FILE) or die "Can't open $DEBUG_FILE";
}        
########################################################
# processing time for C wafers of a lot = A + B * C
my $CONST_A = 0;
my $CONST_B = 1/25;
my $FLAG_MAX = 6;
my $EQP_CNT = 0;

my @AVE_TIME;			# FLAG -> ave for this flag
my @AVE_TIME_ACC;		# FLAG -> ave for flag 1 to this flag
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
		#$RECIPE =~ s/-//g;	# remove - for LP solver

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
####################################
#get the lot ave score
####################################
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
####################################
#get the pilot ave score
####################################
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


########################################################
my $ER_FILE="../data/solution_eqpid_recipe.csv";
my %ER_ASSIGN;		  # (EQPID, FLAG, RECIPE) -> [lot,pilot]
my %EF_COUNT;		  # (EQPID, FLAG) -> [lots,pilots]
my %E_COUNT;		  # (EQPID) -> [lots,pilots] ,contain all flag
my %HANDLE_ER_ASSIGN; # (EQPID, RECIPE, FLAG) -> [lot,pilot] deault should be %ER_ASSIGN's deep copy
my %HANDLE_EF_COUNT;  # (EQPID, FLAG) -> [lots,pilots] deault should be %EF_COUNT's deep copy

my $OP_FLAG = 6;
my %final_score;#store the final total score(lot_score+pilot_score),key is flag
my $switch_cnt = 0;   #recore switch count
my $switch_real_cnt = 0;   #recore switch count
########################################################

#############################################
#read data into %ER_ASSIGN and %EF_COUNT
#############################################
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
    next if($RECIPE eq '');#remove ivalid line
    if($fields[4] =~ /^\s*pilot\s*$/i){
      $PILOT = 1;
    }

    $ER_ASSIGN{$EQPID}{$FLAG}{$RECIPE}=[$LOT,$PILOT];

    if(exists $EF_COUNT{$EQPID}{$FLAG}){
      $EF_COUNT{$EQPID}{$FLAG}=[$EF_COUNT{$EQPID}{$FLAG}[0]+$LOT,$EF_COUNT{$EQPID}{$FLAG}[1]+$PILOT];
    }else{
      $EF_COUNT{$EQPID}{$FLAG}=[$LOT,$PILOT];
    }
  }
  close(FIN);
}

#############################################
#get %E_COUNT from %EF_COUNT
#############################################
sub update_E_COUNT{
  foreach my $E (keys %EF_COUNT){
    $E_COUNT{$E}=[0,0];
    foreach my $F (keys %{$EF_COUNT{$E}}){
      $E_COUNT{$E}[0] += $EF_COUNT{$E}{$F}[0];
      $E_COUNT{$E}[1] += $EF_COUNT{$E}{$F}[1];
      #$E_COUNT{$E}=[$E_COUNT{$E}[0]+$EF_COUNT{$E}{$F}[0],$E_COUNT{$E}[1]+$EF_COUNT{$E}{$F}[1]];
    } 
  }
}

##############################################
#get the lot count on a flag from %HANDLE_EF_COUNT
##############################################
sub get_lots_on_flag1{
  my $FLAG = $_[0];
  my $lot_cnt = 0;
  foreach my $E (sort {$a cmp $b} keys %HANDLE_EF_COUNT){
    foreach my $F (keys %{$HANDLE_EF_COUNT{$E}}){
      if($F eq $FLAG){
        $lot_cnt += $HANDLE_EF_COUNT{$E}{$F}[0];
        #print("$E-$F  $HANDLE_EF_COUNT{$E}{$F}[0]\n");
      }
    }
  }
  return $lot_cnt;
}

##############################################
#get the lot count on a flag from %HANDLE_ER_ASSIGN
##############################################
sub get_lots_on_flag2{
  my $FLAG = $_[0];
  my $lot_cnt = 0;
  foreach my $E (sort {$a cmp $b} keys %HANDLE_ER_ASSIGN){
    foreach my $F (keys %{$HANDLE_ER_ASSIGN{$E}}){
      if($F eq $FLAG){
        foreach my $R (keys %{$HANDLE_ER_ASSIGN{$E}{$F}}){
          print("$E-$F-$R  $HANDLE_ER_ASSIGN{$E}{$F}{$R}[0]\n");
          $lot_cnt += $HANDLE_ER_ASSIGN{$E}{$F}{$R}[0];
        }
      }
    }
  }
  return $lot_cnt;
}

##############################################
#get number of eqpid on a flag
##############################################
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


##############################################
#get the lot ave of <= flag
##############################################
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
  return $lot_cnt/$EQP_CNT;#get_EQP_NUM_ON_FLAG($FLAG);
}

##############################################
#get all flag's flag score per flag
##############################################
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

##############################################
#get flag's pilot score per flag
##############################################
sub get_total_pilot_score_ON_FLAG{
  my $FLAG = $_[0];
  my $pilot_cnt = 0;
  my $score = 0;
  my $THRESHOLD = 3;
  foreach my $E (keys %HANDLE_EF_COUNT){
    $pilot_cnt = 0;#static per eqpid
    foreach my $F (keys %{$HANDLE_EF_COUNT{$E}}){
      if($F == $FLAG){
        $pilot_cnt += $HANDLE_EF_COUNT{$E}{$F}[1];
      }
    }
    my $s = ave_pilot_score($THRESHOLD,$pilot_cnt);
    $score += $s;
    #print("score $E $FLAG $THRESHOLD--$pilot_cnt $s\n");
  }
  return $score;
}

##############################################
#static total score and return (total_score,lot_score,pilot_score)
##############################################
sub get_total_score{
  my $f = $_[0];
  my $lot_score = get_total_lot_score_ON_FLAG($f);
  my $pilot_score = get_total_pilot_score_ON_FLAG($f);
  return ($lot_score+$pilot_score,$lot_score,$pilot_score);
}

##########################################################
#switch recipe between eqpids if the lot&pilot score is smaller then before
##########################################################
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
      $HANDLE_EF_COUNT{$E1}{$FLAG}[1] = $HANDLE_EF_COUNT{$E1}{$FLAG}[1]-$ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]}[1]+$USABLE{$E1}{$R_ARRAY2[$j]} eq "YES"?0:1;
      $HANDLE_EF_COUNT{$E2}{$FLAG}[0] = $HANDLE_EF_COUNT{$E2}{$FLAG}[0]-$ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]}[0]+$ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]}[0];
      $HANDLE_EF_COUNT{$E2}{$FLAG}[1] = $HANDLE_EF_COUNT{$E2}{$FLAG}[1]-$ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]}[1]+$USABLE{$E2}{$R_ARRAY1[$i]} eq "YES"?0:1;

      my ($tmp_score,$lot_score,$pilot_score) = get_total_score($FLAG);
      #print("++++lot_score=$lot_score pilot_score=$pilot_score  $E1-$FLAG-$R_ARRAY1[$i]<-->$E2-$FLAG-$R_ARRAY2[$j]\n");
      if($tmp_score >= $final_score{$FLAG} || $lot_score > $max_total_lot_score || $pilot_score > $max_total_pilot_score){
        undef %HANDLE_EF_COUNT;
        %HANDLE_EF_COUNT = %{dclone(\%EF_COUNT)};
        return;
      }
      print("--$FLAG--lot_score=$lot_score pilot_score=$pilot_score  $E1-$FLAG-$R_ARRAY1[$i]<-->$E2-$FLAG-$R_ARRAY2[$j]\n");

      #changed and deleted recipe from eqpid&flag as reach the requirement
      undef %HANDLE_ER_ASSIGN;
      %HANDLE_ER_ASSIGN = %{dclone(\%ER_ASSIGN)};
      $HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY2[$j]}=[$HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]}[0],$USABLE{$E1}{$R_ARRAY2[$j]} eq "YES"?0:1];
      $HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY1[$i]}=[$HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]}[0],$USABLE{$E2}{$R_ARRAY1[$i]} eq "YES"?0:1];
      print("$E1-$FLAG-$R_ARRAY1[$i] @{$HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]}}==>$E2-$FLAG-$R_ARRAY1[$i] @{$HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY1[$i]}}\n");
      print("$E2-$FLAG-$R_ARRAY2[$j] @{$HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]}}==>$E1-$FLAG-$R_ARRAY2[$j] @{$HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY2[$j]}}\n\n");
      delete $HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R_ARRAY2[$j]};
      delete $HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R_ARRAY1[$i]};

      $final_score{$FLAG} = $tmp_score;
      %EF_COUNT = %{dclone(\%HANDLE_EF_COUNT)};
      %ER_ASSIGN = %{dclone(\%HANDLE_ER_ASSIGN)};
      $switch_real_cnt++;
      
    }
  }
}

##########################################################
#switch recipe between eqpids in same flag
#-1:the eqpid's lot < ave,should be input
# 1:the eqpid's lot > ave+delta,should be output
# 0:the eqpid's lot ~= ave,should be keep it
##########################################################
sub if_need_to_switch_on_eqpid_flag{
  my $E = $_[0];
  my $FLAG = $_[1];
  my $lot_cnt = 0;#static per eqpid
  my $delta = 2;
  my $ave = get_ave_lot_with_flag($FLAG);
  foreach my $F (keys %{$HANDLE_EF_COUNT{$E}}){
    if($F <= $FLAG){
      $lot_cnt += $HANDLE_EF_COUNT{$E}{$F}[0];
    }
  }

  if($lot_cnt<($ave)){
    return -1;
  }elsif($lot_cnt>($ave+$delta)){
    return 1;
  }else{
    return 0;
  }
}

##########################################################
#switch recipe between eqpids on same flag
##########################################################
sub switch_recipe{
  my $E1 = $_[0];
  my $R1 = $_[1];
  my $FLAG1 = $_[2];
  my $E2 = $_[3];
  my $R2 = $_[4];
  my $FLAG2 = $_[5];
  
  #deep copy hash as new hash data in memory
  undef %HANDLE_EF_COUNT;
  %HANDLE_EF_COUNT = %{dclone(\%EF_COUNT)};

  $HANDLE_EF_COUNT{$E1}{$FLAG1}[0] = $HANDLE_EF_COUNT{$E1}{$FLAG1}[0]-$ER_ASSIGN{$E1}{$FLAG1}{$R1}[0]+$ER_ASSIGN{$E2}{$FLAG2}{$R2}[0];
  $HANDLE_EF_COUNT{$E1}{$FLAG1}[1] = $HANDLE_EF_COUNT{$E1}{$FLAG1}[1]-$ER_ASSIGN{$E1}{$FLAG1}{$R1}[1]+$USABLE{$E1}{$R2} eq "YES"?0:1;
  $HANDLE_EF_COUNT{$E2}{$FLAG2}[0] = $HANDLE_EF_COUNT{$E2}{$FLAG2}[0]-$ER_ASSIGN{$E2}{$FLAG2}{$R2}[0]+$ER_ASSIGN{$E1}{$FLAG1}{$R1}[0];
  $HANDLE_EF_COUNT{$E2}{$FLAG2}[1] = $HANDLE_EF_COUNT{$E2}{$FLAG2}[1]-$ER_ASSIGN{$E2}{$FLAG2}{$R2}[1]+$USABLE{$E2}{$R1} eq "YES"?0:1;

  my ($tmp_score,$lot_score,$pilot_score) = get_total_score($OP_FLAG);
  if($tmp_score >= $final_score{$OP_FLAG} || $lot_score > $max_total_lot_score || $pilot_score > $max_total_pilot_score){
    undef %HANDLE_EF_COUNT;
    %HANDLE_EF_COUNT = %{dclone(\%EF_COUNT)};
    return;
  }
  print("--$OP_FLAG--lot_score=$lot_score pilot_score=$pilot_score  $E1-$FLAG1-$R1<-->$E2-$FLAG2-$R2\n");

  #changed and deleted recipe from eqpid&flag as reach the requirement
  undef %HANDLE_ER_ASSIGN;
  %HANDLE_ER_ASSIGN = %{dclone(\%ER_ASSIGN)};
  #may exist the new E-F-R,so need to add
  $HANDLE_ER_ASSIGN{$E1}{$FLAG2}{$R2} = [$HANDLE_ER_ASSIGN{$E1}{$FLAG2}{$R2}[0]+$HANDLE_ER_ASSIGN{$E2}{$FLAG2}{$R2}[0],$USABLE{$E1}{$R2} eq "YES"?0:1];
  $HANDLE_ER_ASSIGN{$E2}{$FLAG1}{$R1} = [$HANDLE_ER_ASSIGN{$E2}{$FLAG1}{$R1}[0]+$HANDLE_ER_ASSIGN{$E1}{$FLAG1}{$R1}[0],$USABLE{$E2}{$R1} eq "YES"?0:1];
  print("$E1-$FLAG1-$R1 @{$HANDLE_ER_ASSIGN{$E1}{$FLAG1}{$R1}}==>$E2-$FLAG1-$R1 @{$HANDLE_ER_ASSIGN{$E2}{$FLAG1}{$R1}}\n");
  print("$E2-$FLAG2-$R2 @{$HANDLE_ER_ASSIGN{$E2}{$FLAG2}{$R2}}==>$E1-$FLAG2-$R2 @{$HANDLE_ER_ASSIGN{$E1}{$FLAG2}{$R2}}\n\n");
  delete $HANDLE_ER_ASSIGN{$E1}{$FLAG1}{$R1};
  delete $HANDLE_ER_ASSIGN{$E2}{$FLAG2}{$R2};

  $final_score{$OP_FLAG} = $tmp_score;
  %EF_COUNT = %{dclone(\%HANDLE_EF_COUNT)};
  %ER_ASSIGN = %{dclone(\%HANDLE_ER_ASSIGN)};
  $switch_real_cnt++;
}

##########################################################
#just invoke the function if R1==R2
#move recipe from E2 to E1
##########################################################
sub move_same_recipe{
  my $E1 = $_[0];
  my $R1 = $_[1];
  my $E2 = $_[2];
  my $R2 = $_[3];
  my $FLAG = $_[4];
  
  #deep copy hash as new hash data in memory
  undef %HANDLE_EF_COUNT;
  %HANDLE_EF_COUNT = %{dclone(\%EF_COUNT)};
  
  $HANDLE_EF_COUNT{$E1}{$FLAG}[0] += $ER_ASSIGN{$E2}{$FLAG}{$R2}[0];
  $HANDLE_EF_COUNT{$E2}{$FLAG}[0] -= $ER_ASSIGN{$E2}{$FLAG}{$R2}[0];
  $HANDLE_EF_COUNT{$E2}{$FLAG}[1] -= $ER_ASSIGN{$E2}{$FLAG}{$R2}[1];

  my ($tmp_score,$lot_score,$pilot_score) = get_total_score($OP_FLAG);
  if($tmp_score >= $final_score{$FLAG} || $lot_score > $max_total_lot_score || $pilot_score > $max_total_pilot_score){
    undef %HANDLE_EF_COUNT;
    %HANDLE_EF_COUNT = %{dclone(\%EF_COUNT)};
    return;
  }
  print("--$OP_FLAG--lot_score=$lot_score pilot_score=$pilot_score  $E2-$FLAG-$R2--->$E1-$FLAG-$R1\n");

  #changed and deleted recipe from eqpid&flag as reach the requirement
  undef %HANDLE_ER_ASSIGN;
  %HANDLE_ER_ASSIGN = %{dclone(\%ER_ASSIGN)};
  
  print("$E2-$FLAG-$R2 @{$HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R2}}===>$E1-$FLAG-$R1 @{$HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R1}}\n");
  $HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R1}[0] +=$HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R2}[0];
  delete $HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R2};

  $final_score{$OP_FLAG} = $tmp_score;
  %EF_COUNT = %{dclone(\%HANDLE_EF_COUNT)};
  %ER_ASSIGN = %{dclone(\%HANDLE_ER_ASSIGN)};
  $switch_real_cnt++;
}

##########################################################
#invoke the function if R1!=R2
#move recipe from E2 to E1
##########################################################
sub move_diff_eqpid{
  my $E1 = $_[0];
  my $E2 = $_[1];
  my $R2 = $_[2];
  my $FLAG = $_[3];
  
  #deep copy hash as new hash data in memory
  undef %HANDLE_EF_COUNT;
  %HANDLE_EF_COUNT = %{dclone(\%EF_COUNT)};
  
  $HANDLE_EF_COUNT{$E1}{$FLAG}[0] += $ER_ASSIGN{$E2}{$FLAG}{$R2}[0];
  $HANDLE_EF_COUNT{$E1}{$FLAG}[1] += $USABLE{$E1}{$R2} eq "YES"?0:1;
  $HANDLE_EF_COUNT{$E2}{$FLAG}[0] -= $ER_ASSIGN{$E2}{$FLAG}{$R2}[0];
  $HANDLE_EF_COUNT{$E2}{$FLAG}[1] -= $ER_ASSIGN{$E2}{$FLAG}{$R2}[1];

  my ($tmp_score,$lot_score,$pilot_score) = get_total_score($OP_FLAG);
  #print("$E2-$FLAG-$R2 @{$ER_ASSIGN{$E2}{$FLAG}{$R2}}====>$E1-$FLAG-$R2\n\n");
  #print("--$FLAG--lot_score=$lot_score pilot_score=$pilot_score  $E2-$FLAG-$R2---->$E1-$FLAG\n");
  if($tmp_score > $final_score{$OP_FLAG}  || $lot_score > $max_total_lot_score || $pilot_score > $max_total_pilot_score){
    undef %HANDLE_EF_COUNT;
    %HANDLE_EF_COUNT = %{dclone(\%EF_COUNT)};
    return;
  }
  print("--$OP_FLAG--lot_score=$lot_score pilot_score=$pilot_score  $E2-$FLAG-$R2---->$E1-$FLAG\n");

  #changed and deleted recipe from eqpid&flag as reach the requirement
  undef %HANDLE_ER_ASSIGN;
  %HANDLE_ER_ASSIGN = %{dclone(\%ER_ASSIGN)};
  #may exist the new E-F-R,so need to add
  $HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R2} = [$HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R2}[0]+$HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R2}[0],$USABLE{$E1}{$R2} eq "YES"?0:1];
  print("$E2-$FLAG-$R2 @{$HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R2}}====>$E1-$FLAG-$R2 @{$HANDLE_ER_ASSIGN{$E1}{$FLAG}{$R2}}\n\n");
  delete $HANDLE_ER_ASSIGN{$E2}{$FLAG}{$R2};

  $final_score{$FLAG} = $tmp_score;
  %EF_COUNT = %{dclone(\%HANDLE_EF_COUNT)};
  %ER_ASSIGN = %{dclone(\%HANDLE_ER_ASSIGN)};
  $switch_real_cnt++;
}

##########################################################
#switch recipe between eqpids if the lot&pilot score is smaller then before and reach if_need_to_switch_on_eqpid_flag
##########################################################
sub switch_recipe_between_eqpid_to_ave{
  my $E1 = $_[0];
  my $E2 = $_[1];
  my @R_ARRAY1;
  my @R_ARRAY2;#store recip id from $RECIPE_def{$RECIPE}
  foreach my $F1 (keys %{$ER_ASSIGN{$E1}}){
    foreach my $R1 (keys %{$ER_ASSIGN{$E1}{$F1}}){
    push(@R_ARRAY1,[$F1,$R1]);
    }
  }
  foreach my $F2 (keys %{$ER_ASSIGN{$E2}}){
    foreach my $R2 (keys %{$ER_ASSIGN{$E2}{$F2}}){
    push(@R_ARRAY2,[$F2,$R2]);
    }
  }
  #for(my $k=0;$k<=$#R_ARRAY1;$k++){
  #  print("$R_ARRAY1[$k][0]-$R_ARRAY1[$k][1] ");
  #}
  #print("$#R_ARRAY1+1\n");

  if(if_need_to_switch_on_eqpid_flag($E1,$OP_FLAG)==0){
    return 0;
  }
  
  for(my $i = 0; $i <= $#R_ARRAY1; $i++){
    for(my $j = 0; $j <= $#R_ARRAY2; $j++){
      my $F1 = $R_ARRAY1[$i][0];my $R1 = $R_ARRAY1[$i][1];
      my $F2 = $R_ARRAY2[$j][0];my $R2 = $R_ARRAY2[$j][1];
      #print("$E1-$FLAG-$R_ARRAY1[$i]<-->$E2-$FLAG-$R_ARRAY2[$j]  $USABLE{$E1}{$R_ARRAY2[$j]}<-->$USABLE{$E2}{$R_ARRAY1[$i]}\n");
      next if($R1=~/^\s*IDLE\s*$/i || $R2=~/^\s*IDLE\s*$/i);
      next if(!(exists $USABLE{$E1}{$R2}) || !(exists $USABLE{$E2}{$R1}));
      #the recipe may be not exist on eqpid&flag,because it may be changed and deleted when reach the requirement
      next if(!(exists $ER_ASSIGN{$E1}{$F1}{$R1}) || !(exists $ER_ASSIGN{$E2}{$F2}{$R2}));
      $switch_cnt++;
      next if(if_need_to_switch_on_eqpid_flag($E1,$OP_FLAG)==-1 && $HANDLE_EF_COUNT{$E1}{$F1}[0]>=$HANDLE_EF_COUNT{$E2}{$F2}[0]);
      next if(if_need_to_switch_on_eqpid_flag($E1,$OP_FLAG)==1 && $HANDLE_EF_COUNT{$E1}{$F1}[0]<=$HANDLE_EF_COUNT{$E2}{$F2}[0]);
      
      if($R1 eq $R2 && $F1 eq $F2){
        print("!!!!!!!!!!!!Here should be run!!!!!!!!!!!!\n");
        exit(111);
        if(if_need_to_switch_on_eqpid_flag($E1,$OP_FLAG)==-1){
          move_same_recipe($E1,$R1,$E2,$R2,$F2);
        }else{
          move_same_recipe($E2,$R2,$E1,$R1,$F1);
        }
      }else{
        switch_recipe($E1,$R1,$F1,$E2,$R2,$F2);
      }

      #if original data is incorrect,you may find that same recipe & same flag on two or more eqpids,so the lots will static fault.
      #use the below lots1 and lots2 to debug it to find the issue.
      #my $lots1= get_lots_on_flag1($FLAG);
      #my $lots2= get_lots_on_flag2($FLAG);
      #print("lots1=$lots1 lots2=$lots2\n") if($lots1 != $lots2);
    }
  }
}

##########################################################
#move recipe from high to low leve between eqpids(highest-lowest)
#E1 is high
#E2 is low
##########################################################
sub move_recipe_high_to_low{
  my $E1 = $_[0];
  my $E2 = $_[1];
  my $FLAG = $_[2];
  my @R_ARRAY1;
  for(my $f = 1; $f <= $FLAG; $f++){
    $R_ARRAY1[$f] = [];
    foreach my $R (keys %{$ER_ASSIGN{$E1}{$f}}){
      push(@{$R_ARRAY1[$f]},$R);
    }
  }

  if(if_need_to_switch_on_eqpid_flag($E1,$OP_FLAG)==0){
    return 0;
  }

  for(my $f = 1; $f <= $FLAG; $f++){
    foreach my $R (@{$R_ARRAY1[$f]}){
      next if($R=~/^\s*IDLE\s*$/i);
      next if(!(exists $USABLE{$E1}{$R}) || !(exists $USABLE{$E2}{$R}));
      #the recipe may be not exist on eqpid&flag,because it may be changed and deleted when reach the requirement
      next if(!(exists $ER_ASSIGN{$E1}{$f}{$R}));
      $switch_cnt++;
      next if(if_need_to_switch_on_eqpid_flag($E1,$OP_FLAG) != 1 || if_need_to_switch_on_eqpid_flag($E2,$OP_FLAG) == 1);

      move_diff_eqpid($E2,$E1,$R,$f);

      #if original data is incorrect,you may find that same recipe & same flag on two or more eqpids,so the lots will static fault.
      #use the below lots1 and lots2 to debug it to find the issue.
      #my $lots1= get_lots_on_flag1($FLAG);
      #my $lots2= get_lots_on_flag2($FLAG);
      #print("lots1=$lots1 lots2=$lots2\n") if($lots1 != $lots2);
  }
  }
}

##########################################################
#store %ER_ASSIGN to file
##########################################################
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

#just print %USABLE
sub print_USABLE{
  foreach my $i (keys(%USABLE)){
    foreach my $j (keys(%{$USABLE{$i}})){
      print("USABLE: $i--$j==>$USABLE{$i}{$j}\n");
    }
  }
}

#just print %EF_COUNT
sub print_EF_COUNT{
  foreach my $E (keys %EF_COUNT){
    foreach my $F (keys %{$EF_COUNT{$E}}){
      if($F <= $OP_FLAG){
        print("$E,$F-->@{$EF_COUNT{$E}{$F}}\n");
      }
    }
  }
}

#just print %E_COUNT
sub print_E_COUNT{
  my @total=(0,0);
  foreach my $E (sort{$a cmp $b} keys %E_COUNT){
      print("$E-->@{$E_COUNT{$E}}\n");
      $total[0] += $E_COUNT{$E}[0];
      $total[1] += $E_COUNT{$E}[1];
  }
  print("(lot,pilot)-->@total\n");
}

#just print eqp num under all flag
sub print_eqp_num_and_ave_lot{
  for(my $f = 1; $f <= $FLAG_MAX; $f++){
    my $e_cnt = get_EQP_NUM_ON_FLAG($f);
    my $l_ave = get_ave_lot_with_flag($f);
    print("FLAG:$f EQP_NUM:$e_cnt LOT_AVE:$l_ave\n");
  }
}

#double check lot score is okay
sub double_check_lot_score{
  my $result = 1;
  for(my $f = 1; $f <= $OP_FLAG; $f++){
    (my $tmp_final_score,my $tmp_lot_score,my $tmp_pilot_score) = get_total_score($f);
    $result=0 if($tmp_lot_score > $max_total_lot_score);
  }
  return $result;
}

#perl optimze_with_pilot.pl:endless loop to run, stop when get crtl+c signal
#perl optimze_with_pilot.pl -f:endless loop to run,but stop when get crtl+c signal or get a okay result on lot score by double_check_lot_score
my $final_lot_good_core = 1000;
my $final_pilot_good_core = 1000;
my $if_exit = 0;
my $repeat_cnt = 0;
my $lot_score_okay = 0;#0 is not okay
my $fast = $ARGV[0];#-f: it mean that program end once get the okay result
$SIG{TERM}=$SIG{INT}=\&get_crtl_c;

##########################################################
#handle ctrl+C or TERM signal to sure program can finish a full process
##########################################################
sub get_crtl_c{
  $if_exit = 1;
  print("!!!!!!!!!!!get ctrl-C signal!!!!!!!!!!!!\n");
}


LOOP:
undef %ER_ASSIGN;
undef %EF_COUNT;
undef %E_COUNT;
$switch_cnt = 0;
$switch_real_cnt = 0;
$repeat_cnt = 0;
read_INPUT();
#print_USABLE();

read_ER_FILE();
update_E_COUNT();

#print_EF_COUNT();
#print_E_COUNT();

#print_eqp_num_and_ave_lot();

$EQP_CNT = keys(%EF_COUNT);

%HANDLE_EF_COUNT=%{dclone(\%EF_COUNT)};
for(my $f = 1; $f <= $OP_FLAG; $f++){
  ($final_score{$f},my $tmp_lot_score,my $tmp_pilot_score) = get_total_score($f);
  print(">>>START_SCORE:$final_score{$f} FLAG:$f lot_score=$tmp_lot_score pilot_score=$tmp_pilot_score\n");
}
#exit(0);

for(my $f = 6; $f <= $OP_FLAG; $f++){
  print("====start optimize flag:$f==========\n");
  ($final_score{$f},my $lot_score,my $pilot_score) = get_total_score($f);
  print(">>>STATIC_SCORE:$final_score{$f} FLAG:$f  lot_score=$lot_score pilot_score=$pilot_score\n");
  
  #get all eqpid from $EQPID_def{$EQPID}
  my @E_ARRAY;#for store all eqpid
  foreach my $E (keys %EQPID_def){
      push(@E_ARRAY,$E);
  }
  #print("@E_ARRAY\n");
  
  my $a_cnt = 0;
  for(my $i = 0; $i <= $#E_ARRAY; $i++){
    #for(my $j = $i+1; $j <= $#E_ARRAY; $j++){
    for(my $j = 0; $i!=$j && $j <= $#E_ARRAY; $j++){
      #print("$E_ARRAY[$i]--$E_ARRAY[$j]\n");
      #switch_recipe_between_eqpid_on_flag($E_ARRAY[$i],$E_ARRAY[$j],$f);
      switch_recipe_between_eqpid_to_ave($E_ARRAY[$i],$E_ARRAY[$j]);
      $a_cnt++;
    }
  }
  print("E_sg:$a_cnt  R_sg:$switch_cnt R_real_sg:$switch_real_cnt\n\n");
  
  
  
  #optimize by move recipe from one to another eqpid
  #get all eqpid on flag 1
  undef @E_ARRAY;#for store flag1's eqpid
  foreach my $E (sort{$E_COUNT{$a}[0]<=>$E_COUNT{$b}[0]} keys %E_COUNT){
      push(@E_ARRAY,$E);
  }
  
  #undef $a_cnt = 0;
  for(my $i = $#E_ARRAY; $i >=0; $i--){
    for(my $j = 0; $j<$i; $j++){
      move_recipe_high_to_low($E_ARRAY[$i],$E_ARRAY[$j],$OP_FLAG);
      $a_cnt++;
    }
  }
  print("E_sg:$a_cnt  R_sg:$switch_cnt R_real_sg:$switch_real_cnt\n\n");
  
  #my $lots=get_lots_on_flag(1);
  #print("lots:$lots\n");

  #try best to sure that every flag's lot score <= $max_total_lot_score
  #but the flag's score may be modified later,because of move_recipe_high_to_low may do not use score as conditions.
  (my $tmp_final_score,my $tmp_lot_score,my $tmp_pilot_score) = get_total_score($f);
  print(">>>STATIC2_SCORE:$final_score{$f} FLAG:$f  lot_score=$tmp_lot_score pilot_score=$tmp_pilot_score\n");
  if($tmp_lot_score>$max_total_lot_score){
    $repeat_cnt++;
    if($repeat_cnt<20){#the largest repeat is 20
      $f--;
      next;
    }else{
      print("!!!!!FLAG:$f No Way To Go!!!!!!!!\n\n");
    }
  }
  $repeat_cnt = 0;
}

undef %HANDLE_EF_COUNT;
%HANDLE_EF_COUNT = %{dclone(\%EF_COUNT)};
($final_score{$OP_FLAG},my $lot_score,my $pilot_score) = get_total_score($OP_FLAG);
print(">>>FINAL_SCORE:$final_score{$OP_FLAG} FLAG:$OP_FLAG lot_score=$lot_score pilot_score=$pilot_score\n");

$lot_score_okay=double_check_lot_score() if($fast eq '-f');

if($lot_score_okay==1 || $lot_score < $final_lot_good_core){
  $final_lot_good_core = $lot_score;
  $final_pilot_good_core = $pilot_score;
  print("FLAG:get one min\n");
  print_ER_ASSIGN();
  if($final_lot_good_core <= 100 && $final_pilot_good_core<=110){
    print(">>>OKAY_CORE---FLAG:$OP_FLAG lot_score=$final_lot_good_core pilot_score=$final_pilot_good_core\n\n");
    goto END;
  }
}

if($lot_score_okay==1 || $if_exit == 1){
  print(">>>NOW_BEST_CORE:---FLAG:$OP_FLAG lot_score=$final_lot_good_core pilot_score=$final_pilot_good_core\n\n");
  goto END;
}else{
  goto LOOP;
}

END:
undef %ER_ASSIGN;
undef %EF_COUNT;
$ER_FILE="./eqpid_recipe_lot_pilot.csv";
read_ER_FILE();
%HANDLE_EF_COUNT=%{dclone(\%EF_COUNT)};
for(my $f = 1; $f <= $OP_FLAG; $f++){
  ($final_score{$f},my $tmp_lot_score,my $tmp_pilot_score) = get_total_score($f);
  print(">>>RESULT_SCORE:$final_score{$f} FLAG:$f lot_score=$tmp_lot_score pilot_score=$tmp_pilot_score\n");
}
exit(0);

