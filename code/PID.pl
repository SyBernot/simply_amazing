#!/usr/bin/perl
use strict;
#init
espeak ('initializing');
my $gpio_cmd='modprobe w1-gpio';
my ($gpio_status, $gpio_output) = executeCommand($gpio_cmd);
my $therm_cmd='modprobe w1-therm';
my ($therm_status, $therm_output) = executeCommand($therm_cmd);

#wiring #
#1-heating
#5      at temp out
#4      cooling out
#29     element out
#12     lower   in
#13     raise   in

my $sensor_cmd='dirname /sys/bus/w1/devices/*/w1_slave';
my ($sensor_status, $sensor_output) = executeCommand($sensor_cmd);
chomp $sensor_output;
my $temp_path = "$sensor_output/w1_slave";

my @inpins = (12,13);
foreach my $pin (@inpins){
  my $cmd="gpio mode $pin in";
  my ($status, $output) = executeCommand($cmd);
  print "setting GPIO_GEN$pin to input\n";
}

#set pins for output
my @outpins=(1,4,5,29);
foreach my $pin(@outpins){
  my $cmd="gpio mode $pin out";
  my ($status, $output) = executeCommand($cmd);
  print "setting GPIO_GEN$pin to output\n";
}

my $imp = 1; #imperial
my $setpoint_file = 'SETPOINT';
#read in last stored
my $set_temp = read_set_point();

my $current_temp;
my $PID_error;
my $previous_error;
my $PID_value;

#my $Kp = 9.1;
#my $Ki = 0.3;
#my $Kd = 1.8;
my $Kp = 2;
my $Ki = 1.5;
my $Kd = .2;

my $PID_p;
my $PID_i;
my $PID_d;
my $previous_time  = time();
my $current_time   = time();

my $logfile = 'data.csv';
open(LOG, ">",  "$logfile") or die "cannot open < $logfile: $!";
print LOG "$current_time,0,0\n";
print "set_temp is $set_temp\n";

main_fork();
while (1){
  $SIG{'INT'} = \&clean_up;
  my $active=check_pins();
  if ($active eq 12){
    lower_set_point();
  }elsif($active eq 13){
    raise_set_point();
  }
  if ($active){
    print "$set_temp\n";
  }
}

sub main_fork{
  my $pid=fork();
  return if $pid;
  while (1){
    print PID_loop();
    print "\n";
    store("$current_time,$current_temp,$PID_p,$PID_i,$PID_d,$PID_value,$PID_error");
    my $duty = $PID_value/10;
    if($PID_error > 0){
      heat    (1,$duty);
      cooling (0,$duty);
      attemp  (0);
    }elsif($PID_error < 0){
      cooling (1,$duty);
      heat    (0,$duty);
      attemp  (0);
    }else{
      attemp  (1);
      heat    (0,$duty);
      cooling (0,$duty);
    }
  }
}
sub PID_loop{
  $current_temp = read_temp ();
  print "$current_temp\n";
  $PID_error = $set_temp-$current_temp;
  print "error: $PID_error = $set_temp-$current_temp\n";
  #calc P
  $PID_p = $Kp*$PID_error;
  print "P: $PID_p = $Kp * $PID_error\n";
  #calc I
  if (-10 < $PID_error && $PID_error < 10){
    $PID_i = $PID_i + ($Ki * $PID_error);
    print "I: $PID_i = $PID_i + ($Ki * $PID_error)\n";
  }

  #store prev time
  $previous_time = $current_time;
  $current_time = time();
  my $dt = $current_time - $previous_time;
  if ($dt ==0){
    $dt=.01;
  }
  print "dt: $dt = $current_time - $previous_time\n";

  #calc D
  $PID_d =$Kd*(($PID_error - $previous_error)/$dt);
  print "D: $PID_d =$Kd*(($PID_error - $previous_error)/$dt)\n";

  #total PID
  $PID_value = $PID_p+$PID_i+$PID_d;
  print "[$PID_value] = [$PID_p] + [$PID_i] + [$PID_d]\n";
  if ($PID_value < 0){
    $PID_value=0;
  }
   if ($PID_value > 100){
    $PID_value=100;
  }

  $previous_error = $PID_error;
  return $PID_value;
}

sub check_pins{
  foreach my $pin(@inpins){
    #print $pin;
    if (readpin ($pin)){
      chomp $pin;
      return $pin;
    }
  }
}

sub readpin {
  my $pin = shift;
  my $cmd="gpio read $pin";
  my ($status, $output) = executeCommand($cmd);
  #print "$pin = $output\n";
  chomp $output;
  return $output;
}

sub read_set_point{
  my $cmd="cat $setpoint_file";
  my ($status, $output) = executeCommand($cmd);
  chomp $output;
  return $output;
}

sub store_temp{
  my  $setpoint = shift;
  unless ($setpoint) {
    $setpoint = 0;
  }
  round($setpoint);
  if (($setpoint >= 0) && ($setpoint <= 220)){
    my $cmd="echo $setpoint > $setpoint_file";
    my ($status, $output) = executeCommand($cmd);
  }
}

sub raise_set_point{
  $set_temp+=.5;
  store_temp($set_temp);
#  print "raise\n";
}

sub lower_set_point{
  $set_temp-=.5;
#  print "lower\n";
  store_temp($set_temp);
}

sub read_temp{
  my $line = `cat $temp_path | grep 't='`;
  $line =~/t=(\d+)/;
  my $reading = (${1}/1000);
  if ($imp){
    $reading=round(c2f($reading));
  }
  return round($reading);
}

sub statechange {
  my $gpio_gen =shift;
  my $bool =shift;
  `gpio write $gpio_gen $bool`;
  print "   toggeling $gpio_gen $bool\n"
}

sub heating {
  my $bool = shift;
  my $duty = shift;
  statechange (1,$bool);
  if ($bool){
    print "HEATING\n";
    sleep $duty;
    statechange (1,0);
  }
}

sub heat {
  my $bool = shift;
  my $duty = shift;
  statechange (29,$bool);
  statechange (1,$bool);
  if ($bool){
    print "HEAT\n";
    sleep $duty;
    statechange (29,0);
    statechange (1,0);
  }
}

sub attemp {
  my $bool = shift;
  statechange (5,$bool);
  if ($bool){
    print "AT TEMP\n";
  }
}

sub cooling {
  my $bool = shift;
  my $duty = shift;
  statechange (4,$bool);
  if ($bool){
    print "COOLING\n";
    sleep $duty;
    statechange (4,0);
  }
}

sub store {
  my $line= shift;
  print LOG "$line\n";
}

sub c2f{
  my $c=shift;
  my $f=($c *9/5)+32;
  return $f;
}

sub f2c{
  my $f=shift;
  my $c=($f -32)*5/9;
  return $c;
}

sub round {
  my $in = shift;
  my $places = 2;
  my $factor = 10**$places;
  my $out = int(($in * $factor)+5) / $factor;
  return $out;
}

sub espeak {
  my $string =shift;
  my $cmd = "espeak -ven-wm+f5 '$string'";
  my ($status, $output) = executeCommand($cmd);
}


sub executeCommand {
###############################################################################
# Usage : executeCommand (command)
# Purpose : executes a command and returns outoput and status
# Returns : exec status, std out
# Parameters: command
# Comments : my ($status, $output) = executeCommand($command)
#              returns 0,null or 1,errorstring
################################################################################
    my $command = join ' ', @_;
    reverse ($_ = qx{$command 2>&1}, $? >> 8);
}

sub clean_up{
  print "caught exit, cleaning up\n";
  foreach my $pin(@outpins){
    statechange ($pin,0);
  }
  close (LOG);
  exit;
}
