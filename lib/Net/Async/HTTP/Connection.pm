#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2013 -- leonerd@leonerd.org.uk

package Net::Async::HTTP::Connection;

use strict;
use warnings;

our $VERSION = '0.32';

use Carp;

use base qw( IO::Async::Stream );
IO::Async::Stream->VERSION( '0.59' ); # ->write( ..., on_write )
use IO::Async::Timer::Countdown;

use HTTP::Response;

my $CRLF = "\x0d\x0a"; # More portable than \r\n

# Indices into responder/ready queue elements
use constant ON_READ  => 0;
use constant ON_ERROR => 1;
use constant IS_DONE  => 2;

# Detect whether HTTP::Message properly trims whitespace in header values. If
# it doesn't, we have to deploy a workaround to fix them up.
#   https://rt.cpan.org/Ticket/Display.html?id=75224
use constant HTTP_MESSAGE_TRIMS_LWS => HTTP::Message->parse( "Name:   value  " )->header("Name") eq "value";

=head1 NAME

C<Net::Async::HTTP::Connection> - HTTP client protocol handler

=head1 DESCRIPTION

This class provides a connection to a single HTTP server, and is used
internally by L<Net::Async::HTTP>. It is not intended for general use.

=cut

sub _init
{
   my $self = shift;
   $self->SUPER::_init( @_ );

   $self->{requests_in_flight} = 0;
}

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( pipeline max_in_flight ready_queue decode_content )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   if( my $on_closed = $params{on_closed} ) {
      $params{on_closed} = sub {
         my $self = shift;

         $self->debug_printf( "CLOSED" );

         $self->error_all( "Connection closed" );

         undef $self->{ready_queue};
         $on_closed->( $self );
      };
   }

   croak "max_in_flight parameter required, may be zero" unless defined $self->{max_in_flight};

   $self->SUPER::configure( %params );
}

sub should_pipeline
{
   my $self = shift;
   return $self->{pipeline} &&
          $self->{can_pipeline} &&
          ( !$self->{max_in_flight} || $self->{requests_in_flight} < $self->{max_in_flight} );
}

sub connect
{
   my $self = shift;
   my %args = @_;

   $self->debug_printf( "CONNECT $args{host}:$args{service}" );

   defined wantarray or die "VOID ->connect";

   $self->SUPER::connect(
      socktype => "stream",
      %args
   )->on_done( sub {
      $self->debug_printf( "CONNECTED" );
      $self->ready;
   });
}

sub ready
{
   my $self = shift;

   my $queue = $self->{ready_queue} or return;

   if( $self->should_pipeline ) {
      $self->debug_printf( "READY pipelined" );
      while( @$queue && $self->should_pipeline ) {
         my $f = shift @$queue;
         next if $f->is_cancelled;

         $f->done( $self );
      }
   }
   elsif( @$queue and $self->is_idle ) {
      $self->debug_printf( "READY non-pipelined" );
      while( @$queue ) {
         my $f = shift @$queue;
         next if $f->is_cancelled;

         $f->done( $self );
         last;
      }
   }
   else {
      $self->debug_printf( "READY cannot-run queue=%d idle=%s",
         scalar @$queue, $self->is_idle ? "Y" : "N");
   }
}

sub is_idle
{
   my $self = shift;
   return $self->{requests_in_flight} == 0;
}

sub _request_done
{
   my $self = shift;
   $self->{requests_in_flight}--;
   $self->debug_printf( "DONE remaining in-flight=$self->{requests_in_flight}" );
   $self->ready;
}

sub on_read
{
   my $self = shift;
   my ( $buffref, $closed ) = @_;

   if( my $head = $self->{responder_queue}[0] ) {
      my $ret = $head->[ON_READ]->( $self, $buffref, $closed, $head );

      if( defined $ret ) {
         return $ret if !ref $ret;

         $head->[ON_READ] = $ret;
         return 1;
      }

      shift @{ $self->{responder_queue} };
      return 1 if !$closed and length $$buffref;
      return;
   }

   # Reinvoked after switch back to baseline, but may be idle again
   return if $closed or !length $$buffref;

   croak "Spurious on_read of connection while idle\n";
}

sub on_write_eof
{
   my $self = shift;
   $self->error_all( "Connection closed", http => undef, undef );
}

sub error_all
{
   my $self = shift;

   while( my $head = shift @{ $self->{responder_queue} } ) {
      $head->[ON_ERROR]->( @_ ) unless $head->[IS_DONE];
   }
}

sub request
{
   my $self = shift;
   my %args = @_;

   my $on_header = $args{on_header} or croak "Expected 'on_header' as a CODE ref";

   my $req = $args{request};
   ref $req and $req->isa( "HTTP::Request" ) or croak "Expected 'request' as a HTTP::Request reference";

   $self->debug_printf( "REQUEST %s %s", $req->method, $req->uri );

   my $request_body = $args{request_body};
   my $expect_continue = !!$args{expect_continue};

   my $method = $req->method;

   if( $method eq "POST" or $method eq "PUT" or length $req->content ) {
      $req->init_header( "Content-Length", length $req->content );
   }

   if( $expect_continue ) {
      $req->init_header( "Expect", "100-continue" );
   }

   if( $self->{decode_content} ) {
      #$req->init_header( "Accept-Encoding", Net::Async::HTTP->can_decode )
      $req->init_header( "Accept-Encoding", "gzip" );
   }

   my $f = $self->loop->new_future;

   # TODO: Cancelling a request Future shouldn't necessarily close the socket
   # if we haven't even started writing the request yet. But we can't know
   # that currently.
   $f->on_cancel( sub { $self->close_now } );

   my $stall_timer;
   my $stall_reason;
   if( $args{stall_timeout} ) {
      $stall_timer = IO::Async::Timer::Countdown->new(
         delay => $args{stall_timeout},
         on_expire => sub {
            my $self = shift;

            my $conn = $self->parent;

            $f->fail( "Stalled while $stall_reason", stall_timeout => );

            $conn->close_now;
         }
      );
      $self->add_child( $stall_timer );
      # Don't start it yet

      my $remove_timer = sub {
         $self->remove_child( $stall_timer ) if $stall_timer;
         undef $stall_timer;
      };

      $f->on_ready( $remove_timer );
      $f->on_cancel( $remove_timer );
   }

   my $on_body_write;
   if( $stall_timer or $args{on_body_write} ) {
      my $inner_on_body_write = $args{on_body_write};
      my $written = 0;
      $on_body_write = sub {
         $stall_timer->reset if $stall_timer;
         $inner_on_body_write->( $written += $_[1] ) if $inner_on_body_write;
      };
   }

   my $on_read = sub {
      my ( $self, $buffref, $closed, $responder ) = @_;

      Scalar::Util::weaken($responder);

      if( $stall_timer ) {
         $stall_reason = "receiving response header";
         $stall_timer->reset;
      }

      unless( $$buffref =~ s/^(.*?$CRLF$CRLF)//s ) {
         if( $closed ) {
            $self->debug_printf( "ERROR closed" );
            $f->fail( "Connection closed while awaiting header", http => undef, $req ) unless $f->is_cancelled;
         }
         return 0;
      }

      my $header = HTTP::Response->parse( $1 );
      # HTTP::Response doesn't strip the \rs from this
      ( my $status_line = $header->status_line ) =~ s/\r$//;

      unless( HTTP_MESSAGE_TRIMS_LWS ) {
         my @headers;
         $header->scan( sub {
            my ( $name, $value ) = @_;
            s/^\s+//, s/\s+$// for $value;
            push @headers, $name => $value;
         } );
         $header->header( @headers ) if @headers;
      }

      my $protocol = $header->protocol;
      if( $protocol =~ m{^HTTP/1\.(\d+)$} and $1 >= 1 ) {
         $self->{can_pipeline} = 1;
      }

      if( $header->code =~ m/^1/ ) { # 1xx is not a final response
         $self->debug_printf( "HEADER [provisional] %s", $status_line );
         $self->write( $request_body,
                       on_write => $on_body_write ) if $request_body and $expect_continue;
         return 1;
      }

      $header->request( $req );
      $header->previous( $args{previous_response} ) if $args{previous_response};

      $self->debug_printf( "HEADER %s", $status_line );

      my $on_body_chunk = $on_header->( $header );

      my $code = $header->code;

      my $content_encoding = $header->header( "Content-Encoding" );

      my $decoder;
      if( $content_encoding and
          $decoder = Net::Async::HTTP->can_decode( $content_encoding ) ) {
         $header->init_header( "X-Original-Content-Encoding" => $header->remove_header( "Content-Encoding" ) );
      }

      # can_pipeline is set for HTTP/1.1 or above; presume it can keep-alive if set
      my $connection_close = lc( $header->header( "Connection" ) || ( $self->{can_pipeline} ? "keep-alive" : "close" ) )
                              eq "close";

      if( $connection_close ) {
         $self->{max_in_flight} = 1;
      }
      elsif( defined( my $keep_alive = lc( $header->header("Keep-Alive") || "" ) ) ) {
         my ( $max ) = ( $keep_alive =~ m/max=(\d+)/ );
         $self->{max_in_flight} = $max if $max && $max < $self->{max_in_flight};
      }

      # RFC 2616 says "HEAD" does not have a body, nor do any 1xx codes, nor
      # 204 (No Content) nor 304 (Not Modified)
      if( $method eq "HEAD" or $code =~ m/^1..$/ or $code eq "204" or $code eq "304" ) {
         $self->debug_printf( "BODY done" );
         $responder->[IS_DONE]++;
         $self->close if $connection_close;
         $f->done( $on_body_chunk->() ) unless $f->is_cancelled;
         $self->_request_done;
         return undef; # Finished
      }

      my $transfer_encoding = $header->header( "Transfer-Encoding" );
      my $content_length    = $header->content_length;

      if( defined $transfer_encoding and $transfer_encoding eq "chunked" ) {
         $self->debug_printf( "BODY chunks" );

         my $chunk_length;

         $stall_reason = "receiving body chunks";
         return sub {
            my ( $self, $buffref, $closed ) = @_;

            $stall_timer->reset if $stall_timer;

            if( !defined $chunk_length and $$buffref =~ s/^(.*?)$CRLF// ) {
               my $header = $1;

               # Chunk header
               unless( $header =~ s/^([A-Fa-f0-9]+).*// ) {
                  $f->fail( "Corrupted chunk header", http => undef, $req ) unless $f->is_cancelled;
                  $self->close_now;
                  return 0;
               }

               $chunk_length = hex( $1 );
               return 1 if $chunk_length;

               my $trailer = "";

               # Now the trailer
               return sub {
                  my ( $self, $buffref, $closed ) = @_;

                  if( $closed ) {
                     $self->debug_printf( "ERROR closed" );
                     $f->fail( "Connection closed while awaiting chunk trailer", http => undef, $req ) unless $f->is_cancelled;
                  }

                  $$buffref =~ s/^(.*)$CRLF// or return 0;
                  $trailer .= $1;

                  return 1 if length $1;

                  # TODO: Actually use the trailer

                  $self->debug_printf( "BODY done" );
                  $responder->[IS_DONE]++;

                  my $final;
                  if( $decoder and not eval { $final = $decoder->(); 1 } ) {
                     $self->debug_printf( "ERROR decode failed" );
                     $f->fail( "Decode error $@", http => undef, $req );
                     $self->close;
                     return undef;
                  }
                  $final = $decoder->() if $decoder;

                  $f->done( $on_body_chunk->() ) unless $f->is_cancelled;
                  $self->_request_done;
                  return undef; # Finished
               }
            }

            # Chunk is followed by a CRLF, which isn't counted in the length;
            if( defined $chunk_length and length( $$buffref ) >= $chunk_length + 2 ) {
               # Chunk body
               my $chunk = substr( $$buffref, 0, $chunk_length, "" );
               undef $chunk_length;

               if( $decoder and not eval { $chunk = $decoder->( $chunk ); 1 } ) {
                  $self->debug_printf( "ERROR decode failed" );
                  $f->fail( "Decode error $@", http => undef, $req );
                  $self->close;
                  return undef;
               }

               unless( $$buffref =~ s/^$CRLF// ) {
                  $self->debug_printf( "ERROR chunk without CRLF" );
                  $f->fail( "Chunk of size $chunk_length wasn't followed by CRLF", http => undef, $req ) unless $f->is_cancelled;
                  $self->close;
               }

               $on_body_chunk->( $chunk );

               return 1;
            }

            if( $closed ) {
               $self->debug_printf( "ERROR closed" );
               $f->fail( "Connection closed while awaiting chunk", http => undef, $req ) unless $f->is_cancelled;
            }
            return 0;
         };
      }
      elsif( defined $content_length ) {
         $self->debug_printf( "BODY length $content_length" );

         if( $content_length == 0 ) {
            $self->debug_printf( "BODY done" );
            $responder->[IS_DONE]++;
            $f->done( $on_body_chunk->() ) unless $f->is_cancelled;
            $self->_request_done;
            return undef; # Finished
         }

         $stall_reason = "receiving body";
         return sub {
            my ( $self, $buffref, $closed ) = @_;

            $stall_timer->reset if $stall_timer;

            # This will truncate it if the server provided too much
            my $content = substr( $$buffref, 0, $content_length, "" );
            $content_length -= length $content;

            if( $decoder and not eval { $content = $decoder->( $content ); 1 } ) {
               $self->debug_printf( "ERROR decode failed" );
               $f->fail( "Decode error $@", http => undef, $req );
               $self->close;
               return undef;
            }

            $on_body_chunk->( $content );

            if( $content_length == 0 ) {
               $self->debug_printf( "BODY done" );
               $responder->[IS_DONE]++;
               $self->close if $connection_close;

               my $final;
               if( $decoder and not eval { $final = $decoder->(); 1 } ) {
                  $self->debug_printf( "ERROR decode failed" );
                  $f->fail( "Decode error $@", http => undef, $req );
                  $self->close;
                  return undef;
               }
               $on_body_chunk->( $final ) if defined $final;

               $f->done( $on_body_chunk->() ) unless $f->is_cancelled;
               $self->_request_done;
               return undef;
            }

            if( $closed ) {
               $self->debug_printf( "ERROR closed" );
               $f->fail( "Connection closed while awaiting body", http => undef, $req ) unless $f->is_cancelled;
            }
            return 0;
         };
      }
      else {
         $self->debug_printf( "BODY until EOF" );

         $stall_reason = "receiving body until EOF";
         return sub {
            my ( $self, $buffref, $closed ) = @_;

            $stall_timer->reset if $stall_timer;

            my $content = $$buffref;
            $$buffref = "";

            if( $decoder and not eval { $content = $decoder->( $content ); 1 } ) {
               $self->debug_printf( "ERROR decode failed" );
               $f->fail( "Decode error $@", http => undef, $req );
               $self->close;
               return undef;
            }

            $on_body_chunk->( $content );

            return 0 unless $closed;

            # TODO: IO::Async probably ought to do this. We need to fire the
            # on_closed event _before_ calling on_body_chunk, to clear the
            # connection cache in case another request comes - e.g. HEAD->GET
            $responder->[IS_DONE]++;
            $self->close;

            $self->debug_printf( "BODY done" );

            my $final;
            if( $decoder and not eval { $final = $decoder->(); 1 } ) {
               $self->debug_printf( "ERROR decode failed" );
               $f->fail( "Decode error $@", http => undef, $req );
               $self->close;
               return undef;
            }
            $on_body_chunk->( $final ) if defined $final;

            $f->done( $on_body_chunk->() ) unless $f->is_cancelled;
            # $self already closed
            $self->_request_done;
            return undef;
         };
      }
   };

   # Unless the request method is CONNECT, the URL is not allowed to contain
   # an authority; only path
   # Take a copy of the headers since we'll be hacking them up
   my $headers = $req->headers->clone;
   my $path;
   if( $method eq "CONNECT" ) {
      $path = $req->uri->as_string;
   }
   else {
      my $uri = $req->uri;
      $path = $uri->path_query;
      $path = "/$path" unless $path =~ m{^/};
      my $authority = $uri->authority;
      if( defined $authority and
          my ( $user, $pass, $host ) = $authority =~ m/^(.*?):(.*)@(.*)$/ ) {
         $headers->init_header( Host => $host );
         $headers->authorization_basic( $user, $pass );
      }
      else {
         $headers->init_header( Host => $authority );
      }
   }

   my $protocol = $req->protocol || "HTTP/1.1";
   my @headers = ( "$method $path $protocol" );
   $headers->scan( sub { push @headers, "$_[0]: $_[1]" } );

   $stall_timer->start if $stall_timer;
   $stall_reason = "writing request";

   my $on_header_write = $stall_timer ? sub { $stall_timer->reset } : undef;

   $self->write( join( $CRLF, @headers ) .
                 $CRLF . $CRLF,
                 on_write => $on_header_write );

   $self->write( $req->content,
                 on_write => $on_body_write ) if length $req->content;
   $self->write( $request_body,
                 on_write => $on_body_write ) if $request_body and !$expect_continue;

   $self->write( "", on_flush => sub {
      $stall_timer->reset if $stall_timer; # test again in case it was cancelled in the meantime
      $stall_reason = "waiting for response";
   }) if $stall_timer;

   $self->{requests_in_flight}++;

   push @{ $self->{responder_queue} }, [ $on_read, sub {
      # Protect against double-fail during ->error_all
      $f->fail( @_ ) unless $f->is_ready;
   } ];

   return $f;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
