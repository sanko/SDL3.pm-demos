use v5.36;
use Carp  qw[croak];
use Affix qw[:all];
use SDL3  qw[:all];
$|++;

# This was an idea I had while trying to get bunny_bench.pl running.
#
# We generate particles that can flow from window to window like water. It's a
# lot like the bunnies but less efficient and instead of bouncing around a
# single window, we bounce around more than one window! Moving windows around
# allows the particles to fall into the lower one if they overlap.
#
# Controls
#  - Hit 'R' on the keyboard to reset the particle burst
#  - Hit ESC to exit (we don't react to the OS request to close windows)
#
# Config
my $WIN_COUNT = 3;                               # Change this for more windows/buckets
my $WIN_W     = 300;
my $WIN_H     = 300;
my $PARTICLES = 800;
my @cols      = generate_palette($WIN_COUNT);    # Window bgs

# Init
SDL_Init(SDL_INIT_VIDEO) || die 'Init Failed: ' . SDL_GetError();

# Setup windows
my @contexts;
my $ptr_x = Affix::calloc( 1, Int );
my $ptr_y = Affix::calloc( 1, Int );
for my $i ( 0 .. $WIN_COUNT - 1 ) {
    my $title = 'Bucket ' . ( $i + 1 );
    my $win   = SDL_CreateWindow( $title, $WIN_W, $WIN_H, SDL_WINDOW_RESIZABLE );
    my $ren   = SDL_CreateRenderer( $win, undef );

    # Cascade positions
    SDL_SetWindowPosition( $win, 200 + ( $i * 150 ), 200 + ( $i * 150 ) );
    push @contexts, {
        win => $win,
        ren => $ren,
        id  => $i,

        # Cache window geometry to avoid calling SDL for every window every frame
        rect => { x => 0, y => 0, w => $WIN_W, h => $WIN_H }
    };
}
my $event_ptr = Affix::malloc(128);

# Particle system
my @particles;
for ( 1 .. $PARTICLES ) {
    push @particles, {

        # Start in Window 0
        ctx => $contexts[0],

        # Local coordinates initially
        x  => rand($WIN_W),
        y  => rand( $WIN_H / 2 ),
        vx => rand(8) - 4,
        vy => rand(5),

        # Particles have pseudo-random colors
        r => 100 + rand(155),
        g => 100 + rand(155),
        b => 255
    };
}
say 'Running... Stack windows to create a waterfall!';

# Main loop
my $running = 1;
while ($running) {

    # Update window geometry
    for my $c (@contexts) {
        SDL_GetWindowPosition( $c->{win}, $ptr_x, $ptr_y );
        $c->{rect}{x} = Affix::cast( $ptr_x, Int );
        $c->{rect}{y} = Affix::cast( $ptr_y, Int );
        SDL_GetWindowSize( $c->{win}, $ptr_x, $ptr_y );
        $c->{rect}{w} = Affix::cast( $ptr_x, Int );
        $c->{rect}{h} = Affix::cast( $ptr_y, Int );
    }

    # Events
    while ( SDL_PollEvent($event_ptr) ) {
        my $h = Affix::cast( $event_ptr, SDL_CommonEvent );
        if    ( $h->{type} == SDL_EVENT_QUIT ) { $running = 0; }
        elsif ( $h->{type} == SDL_EVENT_KEY_DOWN ) {
            my $k = Affix::cast( $event_ptr, SDL_KeyboardEvent );
            if ( $k->{scancode} == SDL_SCANCODE_ESCAPE ) { $running = 0; }

            # Reset
            if ( $k->{scancode} == SDL_SCANCODE_R ) {
                for my $p (@particles) {
                    $p->{ctx} = $contexts[0];
                    $p->{x}   = $contexts[0]->{rect}{w} / 2;
                    $p->{y}   = 50;
                    $p->{vx}  = rand(8) - 4;
                    $p->{vy}  = rand(5);
                }
            }
        }
    }

    # Physics
    for my $p (@particles) {
        $p->{x}  += $p->{vx};
        $p->{y}  += $p->{vy};
        $p->{vy} += 0.3;        # Gravity

        # Get dimensions of current container
        my $cur_rect = $p->{ctx}->{rect};

        # Check Bounds
        my $left   = 0;
        my $right  = $cur_rect->{w};
        my $top    = 0;
        my $bottom = $cur_rect->{h};

        # Has the particle left the current window?
        if ( $p->{x} < $left || $p->{x} > $right || $p->{y} < $top || $p->{y} > $bottom ) {

            # Calculate global desktop position
            my $gx             = $cur_rect->{x} + $p->{x};
            my $gy             = $cur_rect->{y} + $p->{y};
            my $found_new_home = 0;

            # Search for a new window that contains this point
            for my $c (@contexts) {

                # Don't re-check the one we just left (unless we want to support re-entry immediately?)
                # Actually, re-checking is fine if boundaries overlap.
                my $r = $c->{rect};
                if ( $gx >= $r->{x} && $gx <= $r->{x} + $r->{w} && $gy >= $r->{y} && $gy <= $r->{y} + $r->{h} ) {

                    # Transfer!
                    $p->{ctx} = $c;

                    # Convert Global back to Local
                    $p->{x}         = $gx - $r->{x};
                    $p->{y}         = $gy - $r->{y};
                    $found_new_home = 1;
                    last;
                }
            }

            # If no window found, bounce off the invisible wall of the current window
            if ( !$found_new_home ) {

                # Reset to local space logic
                if ( $p->{x} > $right )  { $p->{x} = $right;  $p->{vx} *= -0.8; }
                if ( $p->{x} < $left )   { $p->{x} = $left;   $p->{vx} *= -0.8; }
                if ( $p->{y} > $bottom ) { $p->{y} = $bottom; $p->{vy} *= -0.6; }    # Floor bounce
                if ( $p->{y} < $top )    { $p->{y} = $top;    $p->{vy} *= -0.5; }
            }
        }
    }

    # Render
    for my $ctx (@contexts) {
        my $ren = $ctx->{ren};
        my $id  = $ctx->{id};
        SDL_SetRenderDrawColor( $ren, @{ $cols[$id] }, 255 );
        SDL_RenderClear($ren);
        for my $p (@particles) {
            if ( $p->{ctx} == $ctx ) {
                SDL_SetRenderDrawColor( $ren, $p->{r}, $p->{g}, $p->{b}, 255 );

                # Make them slightly thicker so they are visible
                my $px = $p->{x};
                my $py = $p->{y};
                SDL_RenderFillRect( $ren, { x => $px - 2, y => $py - 2, w => 4, h => 4 } );
            }
        }

        # Draw ID
        SDL_SetRenderDrawColor( $ren, 255, 255, 255, 255 );
        SDL_RenderDebugText( $ren, 10, 10, "Window $id" );
        SDL_RenderPresent($ren);
    }
    SDL_Delay(16);
}

sub generate_palette ($n) {
    return () if $n <= 0;
    my $step = 360.0 / $n;    # Space colors evenly

    # Create a deterministic starting offset based on $n. We multiply $n by a
    # primeish number to ensure the wheel starts at a different rotation for
    # different values of $n.
    my $start_offset = ( $n * 137.508 ) % 360;

    # Saturation: 0.7 (Colorful but not eye-bleeding)
    # Value:      0.95 (Bright)
    map { [ hsv_to_rgb( ( ( $start_offset + ( $_ * $step ) ) % 360 ), 0.70, 0.95 ) ] } 0 .. $n - 1;
}

sub hsv_to_rgb ( $h, $s, $v ) {    # H [0-360], S [0-1], V [0-1] -> (0-255, 0-255, 0-255)
    my $c = $v * $s;
    my $x = $c * ( 1 - abs( ( ( $h / 60.0 ) % 2 ) - 1 ) );
    my $m = $v - $c;
    my ( $r, $g, $b );
    if    ( $h < 60 )  { ( $r, $g, $b ) = ( $c, $x, 0 ) }
    elsif ( $h < 120 ) { ( $r, $g, $b ) = ( $x, $c, 0 ) }
    elsif ( $h < 180 ) { ( $r, $g, $b ) = ( 0, $c, $x ) }
    elsif ( $h < 240 ) { ( $r, $g, $b ) = ( 0, $x, $c ) }
    elsif ( $h < 300 ) { ( $r, $g, $b ) = ( $x, 0, $c ) }
    else               { ( $r, $g, $b ) = ( $c, 0, $x ) }
    int( ( $r + $m ) * 255 ), int( ( $g + $m ) * 255 ), int( ( $b + $m ) * 255 );
}
Affix::free($ptr_x);
Affix::free($ptr_y);
Affix::free($event_ptr);
for my $ctx (@contexts) {
    SDL_DestroyRenderer( $ctx->{ren} );
    SDL_DestroyWindow( $ctx->{win} );
}
SDL_Quit();
