import XCTest

extension XCTestCase {
    func waitFulfill(for expectations: [XCTestExpectation], timeout: Double) async {
#if canImport(Darwin)
        await fulfillment(of: expectations, timeout: timeout)
#else
        wait(for: expectations, timeout: timeout)
#endif
    }
}
