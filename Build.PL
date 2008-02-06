use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'Net::Async::HTTP',
   dist_version_from => 'lib/Net/Async/HTTP/Client.pm',
   build_requires => {
                        'IO::Async::Loop' => 0.12,
                        'Test::More' => 0,
                     },
   license => 'perl',
   create_makefile_pl => 'traditional',
  );
  
$build->create_build_script;
