use strict;
use inc::Module::Install;
name 'CPANPLUS-Dist-Build';
author 'Jos Boumans <kane[at]cpan.org>, Ken Williams <kwilliams@cpan.org>';
version_from 'lib/CPANPLUS/Dist/Build.pm';
abstract 'CPANPLUS plugin to install packages that use Build.PL';
perl_version '5.006';
license 'perl';
auto_license holder => 'Jos Boumans, Ken Williams, Chris Williams and David Golden';
build_requires 'Test::More'          => '0.47';
requires 'Test::Harness'             => '3.16';
requires 'CPANPLUS'                  => '0.84';
requires 'Locale::Maketext::Simple'  => 0;
requires 'Params::Check'             => '0.26';
requires 'IPC::Cmd'                  => '0.42';
requires 'Module::Load'              => '0.16';
requires 'Module::Load::Conditional' => '0.30';
requires 'Module::Pluggable'         => '3.8';
requires 'Module::Build'             => '0.32';
requires 'File::Spec'                => 0;
requires 'ExtUtils::Install'         => '1.42';
requires 'if'                        => 0;
clean_files 't/dummy-cpanplus t/dummy-perl/lib/perl5';
# overwrite the CP::D::B that shipped in core
if ( $] >= 5.009005 && $] < 5.012 ) {
  install_as_core;
}
else {
  install_as_site;
}
eval "githubmeta( 'github' )";
auto_provides;
WriteAll();
