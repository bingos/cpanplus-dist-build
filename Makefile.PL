use ExtUtils::MakeMaker;
use strict;

WriteMakefile (
    NAME            => 'CPANPLUS::Dist::Build',
    VERSION_FROM    => 'lib/CPANPLUS/Dist/Build.pm', # finds $VERSION
    dist            => { COMPRESS => 'gzip -9f', SUFFIX => 'gz' },
    PREREQ_PM       => { 
                        'Test::More'                => 0, 
                        'CPANPLUS'                  => '0.072',
                        'Locale::Maketext::Simple'  => 0,
                        'Params::Check'             => '0.22',
                        'IPC::Cmd'                  => '0.23',
                        'Module::Load::Conditional' => '0.06',
                        'Module::Pluggable'         => '2.4',
                        'Module::Build'             => '0.2611',
                        'File::Spec'                => 0,
                    },
    AUTHOR          => 'Jos Boumans <kane[at]cpan.org>, Ken Williams <kwilliams@cpan.org>',
    ABSTRACT        => 'CPANPLUS plugin to install packages that use Build.PL',
);     
