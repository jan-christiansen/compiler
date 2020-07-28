module Test exposing (..)

import Arduino exposing (Arduino, Output, arduino, digitalPin)


test1 : Int
test1 =
    1 + 2


test2 : Int
test2 =
    1 * 2


test3 : Int
test3 =
    if False then
        1

    else
        0


test4 : Int
test4 =
    id 42


id : Int -> Int
id i =
    i


output : Int -> Output
output n =
    digitalPin (modBy n 2 == 0)


main : Int
main =
    test1 + test2 + test3 + test4



-- main : Arduino Int
-- main =
--     arduino { init = test1 + test2 + test3 + test4, output = output }
-- main : Output
-- main =
--     output 10
