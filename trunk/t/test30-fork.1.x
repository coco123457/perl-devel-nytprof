# Profile data generated by Devel::NYTProf::Reader
# More information at http://search.cpan.org/dist/Devel-NYTProf/
# Format: time,calls,time/call,code
0,0,0,sub prefork {
0,0,0,print "in sub prefork\n";
0,0,0,other();
0,0,0,}
0,0,0,
0,0,0,sub other {
0,2,0,print "in sub other\n";
0,0,0,}
0,0,0,
0,0,0,sub postfork {
0,1,0,print "in sub postfork\n";
0,1,0,other();
0,0,0,}
0,0,0,
0,0,0,prefork();
0,0,0,
0,1,0,fork;
0,0,0,
0,1,0,postfork();
0,1,0,other();
0,0,0,
0,1,0,wait;
