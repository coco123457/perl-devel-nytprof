# Profile data generated by Devel::NYTProf::Reader
# More information at http://search.cpan.org/dist/Devel-NYTProf/
# Format: time,calls,time/call,code
0,0,0,sub foo {
0,2,0,print "in sub foo\n";
0,2,0,bar();
0,0,0,}
0,0,0,
0,0,0,sub bar {
0,7,0,print "in sub bar\n";
0,0,0,}
0,0,0,
0,0,0,sub baz {
0,1,0,print "in sub baz\n";
0,1,0,bar();
0,1,0,bar();
0,1,0,bar();
0,1,0,foo();
0,0,0,}
0,0,0,
0,1,0,bar();
0,0,0,
0,1,0,fork;
0,0,0,
0,1,0,bar();
0,1,0,baz();
0,1,0,foo();
0,0,0,
0,1,0,wait;
