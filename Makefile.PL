use 5.014004;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Lang::Dent',
    VERSION_FROM      => 'lib/Lang/Dent.pm', # finds $VERSION
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/Lang/Dent.pm', # retrieve abstract from module
       AUTHOR         => 'Ben Booth <bbooth@lbl.gov>') : ()),
);
