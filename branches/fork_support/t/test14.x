# Profile data generated by Devel::NYTProf::Reader
# Version
# Author: Adam Kaplan. More information at http://search.cpan.org/~akaplan
# Format: time,calls,time/call,code
0,0,0,BEGIN {
0,0,0,use AutoSplit;
0,0,0,mkdir('./auto');
0,0,0,autosplit('test14', './auto', 1, 0, 0);
0,0,0,}
0,0,0,
0,0,0,use test14;
0,1,0,test14::foo();
0,1,0,test14::bar();