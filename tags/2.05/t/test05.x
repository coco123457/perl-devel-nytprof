# Profile data generated by Devel::NYTProf::Reader
# More information at http://search.cpan.org/dist/Devel-NYTProf/
# Format: time,calls,time/call,code
0,0,0,# Test that fastprof doesn't break
0,0,0,#    &bar;  used as &bar(@_);
0,0,0,
0,0,0,sub foo1 {
0,1,0,print "in foo1(@_)\n";
0,1,0,bar(@_);
0,0,0,}
0,0,0,sub foo2 {
0,1,0,print "in foo2(@_)\n";
0,1,0,&bar;
0,0,0,}
0,0,0,sub bar {
0,2,0,print "in bar(@_)\n";
0,2,0,if( @_ > 0 ){
0,0,0,&yeppers;
0,0,0,}
0,0,0,}
0,0,0,sub yeppers {
0,2,0,print "rest easy\n";
0,0,0,}
0,0,0,
0,1,0,&foo1( A );
0,1,0,&foo2( B );
