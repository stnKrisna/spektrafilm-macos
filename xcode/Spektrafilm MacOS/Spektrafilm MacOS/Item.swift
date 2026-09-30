//
//  Item.swift
//  Spektrafilm MacOS
//
//  Created by Stanislaus Krisna on 12/9/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
