// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CompanionProtocol
import XCTest

final class SkillWireTests: XCTestCase {
    func testApplyRequestCarriesNoTierOrTarget() throws {
        let data = try WireCodec.encode(.request(RequestEnvelope(id: 8, request: .skillsApply)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "request")
        XCTAssertEqual(object["id"] as? Int, 8)
        XCTAssertEqual(object["request"] as? String, "skills_apply")
        XCTAssertEqual(Set(object.keys), Set(["type", "id", "request"]))
    }
}
