# Profile data generated by Devel::NYTProf::Reader
# More information at http://search.cpan.org/dist/Devel-NYTProf/
# Format: time,calls,time/call,code
0,0,0,# test merging of sub calls from eval fids
0,0,0,
0,4,0,sub foo { print "foo\n" }
0,0,0,
0,1,0,my $code = 'foo()';
0,0,0,
0,0,0,# call once from particular line
0,1,0,eval $code;
0,0,0,
0,0,0,# call twice from the same line
0,2,0,eval $code or die $@ for (1,2);
0,0,0,
0,0,0,# once from an eval inside an eval
0,1,0,eval "eval q{$code}";
