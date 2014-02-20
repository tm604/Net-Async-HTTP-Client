use 5.18.2;
use warnings;

use IO::Async::Loop;
use Net::Async::HTTP;
use IO::Async::Timer::Periodic;
use Proc::ProcessTable;
use List::Util 'first';

my $loop = IO::Async::Loop->new;

my $ua = Net::Async::HTTP->new;

$loop->add( $ua );

my $timer = IO::Async::Timer::Periodic->new(
   interval => 0.01,

   on_tick => sub {
      my $f = $ua->GET('http://127.0.0.1');

      warn ((
            first {$_->pid == $$ } @{ Proc::ProcessTable->new->table}
         )->rss / 1024 / 1024 . "Mb")
   },
);
 
$timer->start;
 
$loop->add( $timer );

$loop->run;
