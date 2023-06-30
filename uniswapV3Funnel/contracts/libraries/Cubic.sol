pragma >= 0.6.0;
import "./FullMath.sol";
import "./"
import "@openzeppelin/contracts/utils/SafeCast.sol";
library Cubic {
    function cubicEq(int a , int b, int c, int d) pure returns (int){
        int s0 = b ** 2 - 3*a*c;
        int s1 = 2* b ** 3 - 9*a*b*c + 27*d * a ** 2;

        int m0 = sqrt(s1**2 - 4*s0**3);
        int l0 = ceilCbrt(s1 + m0)
        int l1 = ceilCbrt(s1 - m0)

        int nominator = - (b + l0 + l1);
        int denominator = 3*a;
        
        return (nominator/denominator);
    }

    /**
      * @dev Compute the largest integer smaller than or equal to the cubic root of `n`
    */
    function floorCbrt(uint256 n) internal pure returns (uint256) { unchecked {
        uint256 x = 0;
        for (uint256 y = 1 << 255; y > 0; y >>= 3) {
            x <<= 1;
            uint256 z = 3 * x * (x + 1) + 1;
            if (n / y >= z) {
                n -= y * z;
                x += 1;
            }
        }
        return x;
    }}

    /**
      * @dev Compute the smallest integer larger than or equal to the cubic root of `n`
    */
    function ceilCbrt(uint256 n) internal pure returns (uint256) { unchecked {
        uint256 x = floorCbrt(n);
        return x ** 3 == n ? x : x + 1;
    }}

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

}