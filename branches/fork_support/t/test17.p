sub p1 {
  print "executed code in process 1\n";
  require "t/test17a.pl";
  require "t/test17b.pl";
}

sub p2 {
  print "executed code in process 2\n";
  require "t/test17b.pl";
  require "t/test17a.pl";
}

if(fork) {
  p1();
} else {
  p2();
}
