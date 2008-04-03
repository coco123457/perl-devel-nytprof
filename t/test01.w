bless( {
  "attribute" => {
    "basetime" => 0,
    "ticks_per_sec" => 1000000,
    "xs_version" => 0,
  },
  "fid_filename" => [
    undef,
    "test01.p"
  ],
  "fid_line_time" => [
    undef,
    [
      undef,
      undef,
      [
        0,
        2
      ],
      [
        0,
        2
      ],
      undef,
      undef,
      undef,
      [
        0,
        4
      ],
      undef,
      undef,
      undef,
      [
        0,
        1
      ],
      [
        0,
        1
      ],
      [
        0,
        1
      ],
      undef,
      undef,
      [
        0,
        1
      ],
      [
        0,
        1
      ],
      [
        0,
        1
      ]
    ]
  ],
  "sub_caller" => {
    "main::bar" => {
      1 => {
        12 => 1,
        16 => 1,
        3 => 2
      }
    },
    "main::baz" => {
      1 => {
        17 => 1
      }
    },
    "main::foo" => {
      1 => {
        13 => 1,
        18 => 1
      }
    }
  },
  "sub_fid_line" => {
    "main::bar" => [
      1,
      6,
      8
    ],
    "main::baz" => [
      1,
      10,
      14
    ],
    "main::foo" => [
      1,
      1,
      4
    ]
  }
}, 'Devel::NYTProf::Data' )
